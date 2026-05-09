# frozen_string_literal: true

require 'net/http'
require 'json'

module Llm
  # Thin Net::HTTP client for any OpenAI-compatible chat-completions endpoint.
  # Tries `LLM_MODEL_PRIMARY` first; on any failure (network, 4xx, 5xx, parse)
  # automatically retries with `LLM_MODEL_FALLBACK` once.
  #
  # Default endpoint = OmniRoute on the project's local network.
  #
  # Returns a normalized hash regardless of whether the model emitted text or
  # tool_calls:
  #   { content: String|nil, tool_calls: Array<{id,name,arguments}>|nil, model: String }
  class OmniClient
    class Error < StandardError; end

    PRIMARY  = ENV.fetch('LLM_MODEL_PRIMARY',  'kr/claude-sonnet-4.5')
    FALLBACK = ENV.fetch('LLM_MODEL_FALLBACK', 'cc/claude-sonnet-4-5-20250929')

    def initialize(base_url: ENV['OMNIROUTE_BASE_URL'], api_key: ENV['OMNIROUTE_API_KEY'])
      raise Error, 'OMNIROUTE_BASE_URL not set' if base_url.blank?
      raise Error, 'OMNIROUTE_API_KEY not set'  if api_key.blank?

      @base = base_url.to_s.chomp('/')
      @key  = api_key
    end

    # @param messages    [Array<Hash>] OpenAI-format chat messages.
    # @param tools       [Array<Hash>, nil] OpenAI tool specs (function-style).
    # @param tool_choice [String, Hash, nil] 'auto' (default), 'none', or {type:'function',function:{name:...}}.
    # @return [Hash] { content:, tool_calls:, model: }
    def complete(messages, tools: nil, tool_choice: nil, max_tokens: 1024, temperature: 0.6)
      try_model(PRIMARY, messages, tools, tool_choice, max_tokens, temperature)
    rescue StandardError => e
      Rails.logger.warn("[Llm::OmniClient] primary failed: #{e.class} #{e.message} → fallback")
      try_model(FALLBACK, messages, tools, tool_choice, max_tokens, temperature)
    end

    private

    def try_model(model, messages, tools, tool_choice, max_tokens, temperature)
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

    # Normalizes OpenAI's tool_calls array into a flat list:
    #   [{id:, name:, arguments: <Hash>}, ...]
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
  end
end
