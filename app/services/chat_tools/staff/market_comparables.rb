# frozen_string_literal: true

module ChatTools
  module Staff
    # Issue #173 — staff-инструмент «анализ рынка по объекту» для work_bot.
    # Сотрудник пишет «оцени 1-комн 38 м² Канищево, ул. …» — бот собирает
    # PropertyValuation, гоняет PropertyEvaluationService (внутри — тот же
    # Valuations::WebsearchCompFinder: Tavily → Firecrawl → LLM-парсинг →
    # ExternalListing, city/deal-гейты из #172 нетронуты) и возвращает цену,
    # вилку, ₽/м², уверенность, low_coverage и аналоги СО ССЫЛКАМИ на
    # объявления площадок (ЦИАН/Avito/Я.Недвижимость/Домклик).
    #
    # Каждая оценка сохраняется как PropertyValuation с metadata
    # (source: 'work_bot' + id спросившего) — часть 2 (#175) будет строить
    # по этим записям эмбеддинги для сайт-бота.
    #
    # Security: staff-only — тула живёт только в ChatTools::Staff::Registry,
    # клиентский ChatTools::Registry её не видит (спек на границу).
    module MarketComparables
      REQUIRED = %w[property_type address total_area].freeze
      SUPPORTED_TYPES = %w[apartment house land commercial garage room].freeze
      MAX_COMPARABLES = 8

      def self.schema
        {
          type: 'function',
          function: {
            name: 'market_comparables',
            description: <<~DESC.strip,
              Анализ рынка по объекту недвижимости: экспресс-оценка +
              реальные объявления-аналоги с площадок (ЦИАН, Avito,
              Я.Недвижимость, Домклик) со ссылками, ценами и площадями.

              Вызывай когда сотрудник спрашивает рыночную цену по конкретному
              объекту или сегменту: «оцени 1-комн 38 м² Канищево, ул. …»,
              «по какой цене продаются двушки на Солотче»,
              «вилка цен за дом 8 соток в Канищево»,
              «сколько стоит комната в центре», «анализ рынка по студии 25 м²».

              НЕ вызывай для: поиска лида/клиента по имени или телефону —
              это lookup_lead / search_all_leads; KPI и статистики
              сотрудников — kpi_for; объектов из нашего каталога —
              get_property_details; ипотеки — list_mortgage_programs.
              Если не хватает обязательных полей (property_type, address,
              total_area) — задай ОДИН уточняющий вопрос и вызови тул повторно.

              Если в ответе low_coverage: true — обязательно предупреди
              сотрудника, что аналогов найдено мало и цена ориентировочная,
              а не точная рыночная.
            DESC
            parameters: {
              type: 'object',
              required: REQUIRED,
              properties: {
                property_type:      { type: 'string', enum: SUPPORTED_TYPES },
                deal_type:          { type: 'string', enum: %w[sale rent] },
                address:            { type: 'string', description: 'Полный адрес (например «Рязань, ул. Соборная, 12»)' },
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

      def self.call(args = {}, asked_by: nil)
        args = args.is_a?(Hash) ? args.transform_keys(&:to_s) : {}

        caller = resolve_caller(args, asked_by)
        return { error: 'caller_unknown' } if caller.nil?

        missing = REQUIRED.select { |k| args[k].to_s.strip.empty? }
        return missing_fields_response(missing) if missing.any?

        websearch_ok = websearch_available?
        pv = build_valuation(args, caller)
        enrich_from_geocoder(pv) if pv.latitude.blank? || pv.city.blank?
        # Staff-запрос — не лид: пуш в intake-бот засорил бы воронку лидами
        # из внутренних разборов рынка (hook проверяет thread-local флаг).
        Thread.current[:skip_workbot_push] = true
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

        success_response(pv, result, websearch_ok)
      rescue StandardError => e
        Rails.logger.warn("[ChatTools::Staff::MarketComparables] #{e.class}: #{e.message.to_s.truncate(200)}")
        { error: 'evaluation_failed', message: e.message.to_s.truncate(160) }
      ensure
        Thread.current[:skip_workbot_push] = false
      end

      def self.resolve_caller(args, asked_by)
        return asked_by if asked_by.is_a?(::TelegramUser)

        ::TelegramUser.find_by(id: args['caller_id']) if args['caller_id'].present?
      end

      # Честный дегрейд: без ключей сервис всё равно оценит по внутренней
      # базе (Property/MlsListing/ExternalListing), но площадки не поищет —
      # об этом обязаны знать и бот, и сотрудник (issue #173).
      def self.websearch_available?
        ENV['TAVILY_API_KEY'].to_s.match?(/\A\S+\z/) &&
          ENV['FIRECRAWL_API_KEY'].to_s.match?(/\A\S+\z/)
      end

      def self.build_valuation(args, caller)
        # Участки: оценщик читает land_area (сотки), total_area для land
        # игнорируется (PropertyEvaluationService#subject_area) — писать
        # площадь в оба поля означало бы subject_area == 0 и вечный failed.
        land = args['property_type'].to_s == 'land'
        PropertyValuation.new(
          property_type:      args['property_type'],
          deal_type:          args['deal_type'].presence || 'sale',
          audit_mode:         'express',
          address:            args['address'],
          city:               args['city'].presence,
          district:           args['district'].presence,
          total_area:         land ? nil : args['total_area'],
          land_area:          land ? args['total_area'] : nil,
          rooms:              args['rooms'],
          floor:              args['floor'],
          total_floors:       args['total_floors'],
          building_year:      args['building_year'],
          building_type:      args['building_type'],
          property_condition: args['property_condition'],
          token:              SecureRandom.uuid,
          status:             'pending',
          ip_address:         '0.0.0.0',
          user_agent:         'work_bot',
          metadata:           valuation_metadata(caller)
        )
      end

      # Часть 2 (#175) строит эмбеддинги по staff-оценкам — контракт ключа
      # source='work_bot' и id сотрудника не менять без синхронизации.
      def self.valuation_metadata(caller)
        {
          'source'             => 'work_bot',
          'tool'               => 'market_comparables',
          'asked_by_id'        => caller.id,
          'asked_by_tg_user_id' => caller.tg_user_id,
          'asked_by_username'  => caller.tg_username.to_s,
          'asked_by_label'     => caller.mention,
          'requested_at'       => Time.current.iso8601
        }
      end

      # Best-effort geocode — копия client-side тул'а: без координат/города
      # ComparableFinder деградирует на district/city-median fallback.
      def self.enrich_from_geocoder(pv)
        lookup = Geocoding::AddressLookup.call(pv.address) rescue nil
        return unless lookup

        pv.latitude  ||= lookup.latitude
        pv.longitude ||= lookup.longitude
        pv.city      ||= lookup.city.to_s.sub(/^\s*г\.?\s*/i, '').presence
        pv.district  ||= lookup.district if lookup.district.present?
      end

      def self.success_response(pv, result, websearch_ok)
        status = websearch_status(websearch_ok, pv)
        {
          success:          true,
          valuation_token:  pv.token,
          property_type:    pv.property_type,
          address:          pv.address,
          city:             pv.city,
          estimated_price:  result[:estimated_price].to_i,
          min_price:        result[:min_price].to_i,
          max_price:        result[:max_price].to_i,
          price_per_sqm:    result[:price_per_sqm].to_i,
          confidence_level: result[:confidence_level].to_f,
          low_coverage:     result[:low_coverage] == true,
          websearch:        status,
          market_note:      market_note(status),
          comparables:      serialize_comparables(result[:comparables])
        }
      end

      # Пайплайн площадок ищет только продажу (WebsearchCompFinder fail-close
      # для rent, issue #172) — для аренды честно сообщаем, что поиск не
      # выполнялся, а не отчитываемся ложным 'ok'.
      def self.websearch_status(websearch_ok, pv)
        return 'unavailable' unless websearch_ok
        return 'skipped_rent' if pv.deal_type.to_s == 'rent'

        'ok'
      end

      def self.market_note(status)
        case status
        when 'unavailable'
          'Поиск по площадкам недоступен (не заданы ключи Tavily/Firecrawl) — ' \
            'оценка по внутренней базе, без свежих объявлений с площадок.'
        when 'skipped_rent'
          'Поиск по площадкам выполняется только для продажи — для аренды ' \
            'оценка по внутренней базе, без свежих объявлений с площадок.'
        end
      end

      # Аналоги со ссылками вперёди: staff-запрос ценится именно ссылками
      # на объявления (issue #173); внутренние comps (относительные url вида
      # /properties/:id) — в хвосте и не помечаются external.
      def self.serialize_comparables(comps)
        Array(comps)
          .map { |c| serialize_comparable(c) }
          .sort_by { |c| c[:external] ? 0 : 1 }
          .first(MAX_COMPARABLES)
      end

      def self.serialize_comparable(c)
        url = c[:url].to_s.presence
        {
          title:         c[:title].to_s.truncate(120),
          url:           url,
          price:         c[:price].to_i,
          price_per_sqm: c[:price_per_sqm].to_i,
          area:          c[:area].to_f,
          rooms:         c[:rooms],
          district:      c[:district].to_s,
          source:        c[:source].to_s,
          external:      url.to_s.start_with?('http')
        }
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
          message: "Не хватает данных: #{missing.map { |k| hints[k] || k }.join(', ')}. Уточни у сотрудника и вызови тул повторно."
        }
      end

      def self.run_failure(pv, error_message)
        pv.update_columns(status: 'failed', evaluation_data: { error: error_message.to_s })
        { error: 'evaluation_failed', message: error_message.to_s.truncate(160), token: pv.token }
      end
    end
  end
end
