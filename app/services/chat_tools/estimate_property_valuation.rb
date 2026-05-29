# frozen_string_literal: true

module ChatTools
  # Express valuation tool — wraps PropertyEvaluationService so the
  # chatbot can answer "сколько стоит моя квартира?" without redirecting
  # the user out of chat. Creates a real PropertyValuation row (so the
  # operator can review the request in admin), runs the synchronous
  # estimator, returns a compact summary + a deep link to the full
  # result page.
  #
  # Required fields: property_type, address, total_area. The LLM is
  # instructed to ask for any missing fields rather than escalating; this
  # module also returns a structured "missing_fields" error so the bot
  # gets a deterministic signal.
  #
  # CRM lead creation is intentionally OFF here — the chat hasn't yet
  # collected an email/phone for follow-up. The bot can ask for those
  # later in a separate turn and trigger the lead creation flow then.
  module EstimatePropertyValuation
    REQUIRED = %w[property_type address total_area].freeze
    SUPPORTED_TYPES = %w[apartment house land commercial garage room].freeze

    def self.schema
      {
        type: 'function',
        function: {
          name: 'estimate_property_valuation',
          description: <<~DESC.strip,
            Экспресс-оценка стоимости любого объекта недвижимости (квартира,
            дом, участок, комната, коммерция, гараж) по адресу, площади и
            характеристикам. Возвращает estimated_price, вилку min/max,
            confidence, ai_summary, ссылку на полный отчёт.

            Вызывай ВСЕГДА когда пользователь спрашивает «сколько стоит моя
            квартира / дом / участок», «оцените мой объект», «какая
            рыночная цена», «во сколько оценить». НЕ путать с
            run_investment_audit — этот тул работает с объектом
            ПОЛЬЗОВАТЕЛЯ, run_investment_audit — с объектом каталога.

            Если у тебя не хватает обязательных полей (property_type,
            address, total_area) — задай ОДИН уточняющий вопрос:
            «Назовите адрес, общую площадь, число комнат, этаж и состояние
            ремонта». НЕ эскалируй на человека. НЕ отправляй на
            /valuations/new. Собери в диалоге и вызови тул.
          DESC
          parameters: {
            type: 'object',
            required: REQUIRED,
            properties: {
              property_type:      { type: 'string', enum: SUPPORTED_TYPES },
              deal_type:          { type: 'string', enum: %w[sale rent] },
              address:            { type: 'string', description: 'Полный адрес (например «Москва, ул. Тверская, 1»)' },
              city:               { type: 'string' },
              district:           { type: 'string' },
              total_area:         { type: 'number', description: 'Общая площадь в м² (для участка — в сотках)' },
              rooms:              { type: 'integer' },
              floor:              { type: 'integer' },
              total_floors:       { type: 'integer' },
              building_year:      { type: 'integer' },
              building_type:      { type: 'string', enum: %w[panel brick monolith block wood stalin] },
              property_condition: { type: 'string', enum: %w[needs_repair average good excellent designer] }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args)
      args = args.is_a?(Hash) ? args.transform_keys(&:to_s) : {}

      missing = REQUIRED.select { |k| args[k].to_s.strip.empty? }
      return missing_fields_response(missing) if missing.any?

      pv = build_valuation(args)
      enrich_from_geocoder(pv) if pv.latitude.blank? || pv.city.blank?

      pv.save!(validate: false)

      result = PropertyEvaluationService.new(pv).call
      return run_failure(pv, result[:error]) unless result[:success]

      pv.update_columns(
        estimated_price:  result[:estimated_price],
        min_price:        result[:min_price],
        max_price:        result[:max_price],
        confidence_level: result[:confidence_level],
        evaluation_data:  result.except(:success),
        status:           'completed',
        updated_at:       Time.current
      )

      compact_response(pv, result)
    rescue StandardError => e
      Rails.logger.warn("[ChatTools::EstimatePropertyValuation] #{e.class}: #{e.message.to_s.truncate(200)}")
      { error: 'evaluation_failed', message: e.message.to_s.truncate(160) }
    end

    def self.missing_fields_response(missing)
      hints = {
        'property_type' => 'тип объекта (apartment/house/land/commercial/room/garage)',
        'address'       => 'полный адрес',
        'total_area'    => 'общая площадь в м² (или соток для участка)'
      }
      {
        error:   'missing_fields',
        missing: missing,
        message: "Не хватает данных: #{missing.map { |k| hints[k] || k }.join(', ')}. Уточни у пользователя и вызови тул повторно."
      }
    end

    def self.build_valuation(args)
      PropertyValuation.new(
        property_type:      args['property_type'],
        deal_type:          args['deal_type'].presence || 'sale',
        audit_mode:         'express',
        address:            args['address'],
        city:               args['city'].presence,
        district:           args['district'].presence,
        total_area:         args['total_area'],
        rooms:              args['rooms'],
        floor:              args['floor'],
        total_floors:       args['total_floors'],
        building_year:      args['building_year'],
        building_type:      args['building_type'],
        property_condition: args['property_condition'],
        token:              SecureRandom.uuid,
        status:             'pending',
        ip_address:         '0.0.0.0',
        user_agent:         'chat-bot'
      )
    end

    # Best-effort geocode. We populate latitude/longitude + city/district
    # from DaData (or Yandex fallback) so ComparableFinder's geo-band
    # search and the city-median fallback both work. Silent on failure —
    # the evaluator still produces a result using whatever's left.
    def self.enrich_from_geocoder(pv)
      lookup = Geocoding::AddressLookup.call(pv.address) rescue nil
      return unless lookup

      pv.latitude  ||= lookup.latitude
      pv.longitude ||= lookup.longitude
      pv.city      ||= lookup.city.to_s.sub(/^\s*г\.?\s*/i, '').presence
      pv.district  ||= lookup.district if lookup.district.present?
    end

    def self.compact_response(pv, result)
      {
        success:           true,
        token:             pv.token,
        result_url:        "/valuations/#{pv.token}/result",
        property_type:     pv.property_type,
        address:           pv.address,
        city:              pv.city,
        estimated_price:   result[:estimated_price].to_i,
        min_price:         result[:min_price].to_i,
        max_price:         result[:max_price].to_i,
        price_per_sqm:     result[:price_per_sqm].to_i,
        confidence_level:  result[:confidence_level].to_f,
        tier:              result[:tier].to_i,
        comparables_count: Array(result[:comparables]).size,
        ai_summary:        result[:ai_summary].to_s.truncate(600)
      }
    end

    def self.run_failure(pv, error_message)
      pv.update_columns(status: 'failed', evaluation_data: { error: error_message.to_s })
      { error: 'evaluation_failed', message: error_message.to_s.truncate(160), token: pv.token }
    end
  end
end
