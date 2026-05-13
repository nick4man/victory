# frozen_string_literal: true

require 'net/http'
require 'json'

module Llm
  # OpenAI-compatible chat-completions client with multi-model fallback chain.
  # Tries the cheapest free models first, escalates through cheap-paid tiers,
  # and only falls back to premium models (Claude Sonnet) when every cheaper
  # option in the chain has failed. The chain is selectable per call: pass
  # `chain: :chat` for conversational use, `chain: :analysis` for structured
  # JSON/reasoning. Override via `LLM_CHAIN_CHAT` / `LLM_CHAIN_ANALYSIS` env
  # vars (comma-separated model IDs).
  #
  # Why a chain instead of a single model:
  #   - Reliability: any one provider can rate-limit or go down. With 9
  #     attempts we get high uptime without paying premium prices.
  #   - Cost: each free-tier hit costs zero. Premium Sonnet sits at the
  #     end and is rarely reached in steady-state.
  #   - Observability: every successful answer is logged with the model
  #     that produced it + counted in Redis, so we can see distribution.
  class OmniClient
    class Error < StandardError; end

    DEFAULT_CHAINS = {
      chat: %w[
        openrouter/meta-llama/llama-3.3-70b-instruct:free
        openrouter/qwen/qwen3-next-80b-a3b-instruct:free
        groq/llama-3.3-70b-versatile
        openrouter/google/gemma-4-31b-it:free
        openrouter/z-ai/glm-4.5-air:free
        groq/meta-llama/llama-4-scout-17b-16e-instruct
        gemini/gemini-2.5-flash
        ds/deepseek-v4-flash
        kr/claude-sonnet-4.5
      ],
      analysis: %w[
        openrouter/openai/gpt-oss-120b:free
        openrouter/z-ai/glm-4.5-air:free
        openrouter/qwen/qwen3-next-80b-a3b-instruct:free
        groq/openai/gpt-oss-120b
        cerebras/zai-glm-4.7
        cf/@cf/meta/llama-3.3-70b-instruct
        gemini/gemini-2.5-flash
        ds/deepseek-v4-flash
        kr/claude-sonnet-4.5
      ]
    }.freeze

    def self.chain_for(key)
      env_var = "LLM_CHAIN_#{key.to_s.upcase}"
      env_value = ENV[env_var]
      return env_value.split(',').map(&:strip).reject(&:empty?) if env_value.present?

      DEFAULT_CHAINS.fetch(key.to_sym, DEFAULT_CHAINS[:chat])
    end

    def initialize(base_url: ENV['OMNIROUTE_BASE_URL'], api_key: ENV['OMNIROUTE_API_KEY'])
      raise Error, 'OMNIROUTE_BASE_URL not set' if base_url.blank?
      raise Error, 'OMNIROUTE_API_KEY not set'  if api_key.blank?

      @base = base_url.to_s.chomp('/')
      @key  = api_key
    end

    # @param messages    [Array<Hash>] OpenAI-format chat messages.
    # @param chain       [Symbol] :chat (default) or :analysis.
    # @param tools       [Array<Hash>, nil] OpenAI tool specs.
    # @param tool_choice [String, Hash, nil] 'auto' (default), 'none', or a function spec.
    # @return [Hash] { content:, tool_calls:, model:, attempts: }
    def complete(messages, chain: :chat, tools: nil, tool_choice: nil,
                 max_tokens: 1024, temperature: 0.6, response_format: nil)
      models = self.class.chain_for(chain)
      raise Error, "empty chain for #{chain}" if models.empty?

      last_error = nil
      models.each_with_index do |model, idx|
        begin
          result = try_model(model, messages, tools, tool_choice,
                             max_tokens, temperature, response_format)
          Rails.logger.info(
            "[Llm::OmniClient] chain=#{chain} answered_by=#{model} attempt=#{idx + 1}/#{models.size}"
          )
          increment_metric(chain, model)
          return result.merge(attempts: idx + 1)
        rescue StandardError => e
          last_error = e
          Rails.logger.warn(
            "[Llm::OmniClient] chain=#{chain} #{model} failed (#{e.class}: #{e.message.to_s.truncate(160)}), trying next"
          )
        end
      end

      raise(last_error || Error.new("all #{models.size} models in chain=#{chain} failed"))
    end

    private

    # Per-model attempt. Raises on any failure (HTTP non-2xx, JSON parse,
    # empty content+no tool_calls) so the outer loop moves to the next.
    def try_model(model, messages, tools, tool_choice, max_tokens, temperature, response_format)
      uri = URI("#{@base}/chat/completions")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type']  = 'application/json'
      req['Authorization'] = "Bearer #{@key}"

      body = {
        model:       model,
        messages:    messages,
        max_tokens:  max_tokens,
        temperature: temperature,
        stream:      false
      }
      body[:response_format] = response_format if response_format
      if tools.present?
        body[:tools]       = tools
        body[:tool_choice] = tool_choice || 'auto'
      end
      req.body = JSON.generate(body)

      res = Net::HTTP.start(uri.host, uri.port,
                            use_ssl:      uri.scheme == 'https',
                            open_timeout: 5,
                            read_timeout: 60) { |h| h.request(req) }

      raise Error, "HTTP #{res.code}: #{res.body.to_s.truncate(300)}" unless res.is_a?(Net::HTTPSuccess)

      data    = JSON.parse(res.body)
      message = data.dig('choices', 0, 'message') || {}
      content    = message['content'].is_a?(String) ? message['content'] : nil
      tool_calls = parse_tool_calls(message['tool_calls'])

      raise Error, "empty content + no tool_calls; raw: #{data.inspect.truncate(300)}" if content.to_s.empty? && tool_calls.blank?

      { content: content, tool_calls: tool_calls, model: model }
    end

    def parse_tool_calls(raw)
      return nil if raw.blank?

      Array(raw).map do |tc|
        fn        = tc['function'] || {}
        arguments = fn['arguments'].is_a?(String) ? safe_parse_json(fn['arguments']) : (fn['arguments'] || {})
        {
          id:        tc['id'],
          name:      fn['name'],
          arguments: arguments
        }
      end
    end

    def safe_parse_json(str)
      JSON.parse(str)
    rescue JSON::ParserError
      Rails.logger.warn("[Llm::OmniClient] tool_call.arguments not valid JSON: #{str.truncate(120)}")
      {}
    end

    # Cost-analytics: counter per chain/model. Best-effort — never breaks
    # the request if Redis is unavailable.
    def increment_metric(chain, model)
      return unless defined?(Rails) && Rails.application

      redis = redis_connection
      return unless redis

      key = "omni:#{chain}:#{model}"
      redis.incr(key)
    rescue StandardError => e
      Rails.logger.debug("[Llm::OmniClient] metric increment skipped: #{e.message}")
    end

    def redis_connection
      @redis ||= begin
        url = ENV['REDIS_URL'].presence || 'redis://localhost:6379/0'
        require 'redis' unless defined?(Redis)
        Redis.new(url: url)
      rescue StandardError
        nil
      end
    end
  end
end
