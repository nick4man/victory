# frozen_string_literal: true

module Llm
  # Round-trip loop for LLM tool-calling.
  #
  # Call flow:
  #   1. Send {messages, tools} to LLM.
  #   2. If response contains tool_calls — execute each via the registry,
  #      append `role: 'tool'` messages back, GOTO 1.
  #   3. Otherwise — return final assistant content.
  #
  # Bounded by `max_iterations` so a misbehaving model can't infinite-loop us.
  # Logs every tool call for later post-mortem in ChatMessage#metadata.
  class ToolRunner
    DEFAULT_MAX_ITERATIONS = 5

    Result = Struct.new(:content, :model, :tool_log, keyword_init: true)

    def initialize(client: Llm::OmniClient.new, registry: ChatTools::Registry, max_iterations: DEFAULT_MAX_ITERATIONS)
      @client         = client
      @registry       = registry
      @max_iterations = max_iterations
    end

    # @param messages [Array<Hash>] standard OpenAI format
    # @param max_tokens [Integer]
    # @param temperature [Float]
    # @return [Result]
    def call(messages, max_tokens: 1024, temperature: 0.6)
      conversation = messages.dup
      tool_log     = []
      model        = nil

      @max_iterations.times do |iteration|
        response = @client.complete(
          conversation,
          tools:       @registry.schemas,
          tool_choice: 'auto',
          max_tokens:  max_tokens,
          temperature: temperature
        )
        model = response[:model]

        # Final answer arrived.
        if response[:tool_calls].blank?
          return Result.new(content: response[:content].to_s, model: model, tool_log: tool_log)
        end

        # Append assistant turn with tool_calls so the next request includes the
        # round-trip context (OpenAI format requires the assistant message that
        # contained the tool_calls before the corresponding `role: tool` rows).
        conversation << {
          role:       'assistant',
          content:    response[:content],
          tool_calls: response[:tool_calls].map do |tc|
            { id: tc[:id], type: 'function',
              function: { name: tc[:name], arguments: JSON.generate(tc[:arguments]) } }
          end
        }

        response[:tool_calls].each do |tc|
          result = @registry.call(tc[:name], tc[:arguments])
          tool_log << { iteration: iteration, name: tc[:name], args: tc[:arguments], result_preview: result_preview(result) }
          conversation << {
            role:         'tool',
            tool_call_id: tc[:id],
            name:         tc[:name],
            content:      JSON.generate(result)
          }
        end
      end

      # If we exit the loop without a final answer, return whatever the last
      # iteration provided (or a hard failure message).
      Result.new(
        content:  'Не получилось ответить за разумное число шагов — позову агента.',
        model:    model || 'unknown',
        tool_log: tool_log
      )
    end

    private

    def result_preview(result)
      json = result.is_a?(String) ? result : JSON.generate(result)
      json.length > 400 ? "#{json[0...400]}…" : json
    rescue StandardError
      result.inspect.truncate(400)
    end
  end
end
