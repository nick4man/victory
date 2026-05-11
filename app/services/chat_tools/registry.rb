# frozen_string_literal: true

module ChatTools
  # Single source of truth: which tools the chatbot exposes and how to call them.
  # Llm::ToolRunner consumes #schemas (for the LLM) and #call(name, args) (for execution).
  module Registry
    HANDLERS = {
      'search_properties'        => ChatTools::SearchProperties,
      'semantic_search'          => ChatTools::SemanticSearch,
      'get_property_details'     => ChatTools::GetPropertyDetails,
      'aggregate_market'         => ChatTools::AggregateMarket,
      'find_in_district_polygon' => ChatTools::FindInDistrictPolygon,
      'submit_review'            => ChatTools::SubmitReview,
      'run_investment_audit'     => ChatTools::RunInvestmentAudit
    }.freeze

    module_function

    def schemas
      HANDLERS.values.map(&:schema)
    end

    # Dispatches a tool call by name. Symbolizes args (LLMs return string keys).
    # Wraps errors so the LLM gets a structured "error" rather than crashing.
    def call(name, args)
      handler = HANDLERS[name.to_s]
      return { error: 'unknown_tool', tool: name } unless handler

      handler.call(deep_symbolize(args))
    rescue StandardError => e
      Rails.logger.warn("[ChatTools] #{name} failed: #{e.class} #{e.message}")
      { error: 'tool_failed', tool: name, message: e.message.to_s.truncate(180) }
    end

    def deep_symbolize(obj)
      case obj
      when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
      when Array then obj.map { |v| deep_symbolize(v) }
      else            obj
      end
    end
  end
end
