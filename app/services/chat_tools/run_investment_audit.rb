# frozen_string_literal: true

module ChatTools
  # Launches a full Investment Audit (EI + Monte Carlo) for a specific
  # property in the catalog and returns a URL where the user can read the
  # verdict once the Sidekiq job finishes (~30s).
  #
  # Async pattern — DOES NOT block the LLM tool-loop on the engine's 14s
  # MC computation. The flow:
  #   1. resolve `property_slug` → Property
  #   2. cheap engine health-check (fail fast if circuit is open)
  #   3. create PropertyValuation pre-filled from the property
  #   4. enqueue InvestmentAuditJob (Sidekiq picks it up)
  #   5. return `{ status: 'queued', audit_url, token }` immediately
  # The bot then tells the user "запустил, открываю отчёт: <link>" and the
  # existing /valuations/audit/:token loader page (with vanilla polling)
  # handles the wait.
  module RunInvestmentAudit
    # Same enum mappings used by Valuations::InvestmentController#prefill_from_property!
    # See app/controllers/valuations/investment_controller.rb for canonical version.
    REALTY_TO_PV_TYPE = { 'flat' => 'apartment', 'commerce' => 'commercial' }.freeze
    CONDITION_TO_PV   = { 'normal' => 'average', 'renovated' => 'good', 'euro' => 'excellent' }.freeze

    def self.schema
      {
        type: 'function',
        function: {
          name: 'run_investment_audit',
          description: <<~DESC.strip,
            Запускает инвестиционный аудит конкретного объекта из каталога. Возвращает audit_url — ссылку на отчёт с вердиктом BUY/WAIT/NEUTRAL, EI (cash/mortgage/deposit), Monte Carlo 1M симуляций, рисками. Расчёт ~30 секунд в фоне.

            Вызывай ВСЕГДА когда пользователь на странице объекта или в контексте конкретного slug спрашивает: "стоит ли покупать", "окупится ли", "это инвестиционно выгодно", "сколько лет окупаемость", "ROI", "сравни с депозитом / ипотекой", "запусти инвест-аудит".

            НЕ вызывай для вопросов "сколько стоит" / "какая цена" / "опиши объект" — для этого есть get_property_details. НЕ вызывай если у тебя нет конкретного property_slug — попроси пользователя уточнить объект.
          DESC
          parameters: {
            type: 'object',
            required: %w[property_slug],
            properties: {
              property_slug: {
                type: 'string',
                description: 'FriendlyId slug объекта из каталога victory62 (как в URL /properties/<slug>). Берётся из контекста страницы или предыдущего get_property_details.'
              }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args)
      slug = args.is_a?(Hash) ? args[:property_slug].to_s : args.to_s
      return { error: 'missing_slug', message: 'property_slug обязателен' } if slug.blank?

      prop = Property.friendly.find(slug)

      # Fail fast if engine is down — circuit-open / unreachable. Saves the
      # user from clicking a loader link that'll just sit and time out.
      AuditEngine::Client.new.health

      valuation = build_valuation(prop)
      InvestmentAuditJob.perform_later(valuation.id)

      {
        status: 'queued',
        token: valuation.token,
        report_number: valuation.report_number,
        report_label: valuation.report_label,
        audit_url: ChatTools::Url.investment_audit_path(valuation.token),
        property_slug: prop.slug,
        property_title: ChatTools::Format.sanitize_text(prop.title),
        message: "Запущен аудит «#{prop.title.truncate(60)}» — отчёт #{valuation.report_label}. Будет готов через ~30 секунд."
      }
    rescue ActiveRecord::RecordNotFound
      { error: 'property_not_found', slug: slug,
        message: "Объект «#{slug}» не найден в каталоге." }
    rescue AuditEngine::UnavailableError => e
      Rails.logger.info("[ChatTools::RunInvestmentAudit] engine unavailable: #{e.message}")
      { error: 'engine_unavailable',
        message: 'Сервис аудита временно недоступен. Попробуйте через пару минут.' }
    end

    def self.build_valuation(prop)
      realty_slug = prop.property_type&.slug
      pv_type = REALTY_TO_PV_TYPE.fetch(realty_slug, realty_slug || 'apartment')
      area_value = realty_slug == 'land' ? nil : prop.area
      land_value = if prop.land_area_m2.present? && prop.land_area_m2.positive?
                     (prop.land_area_m2.to_f / 100.0).round(2)
                   end

      PropertyValuation.create!(
        audit_mode: 'investment',
        status: 'pending',
        property_type: pv_type,
        deal_type: 'sale',
        address: prop.address, city: 'Рязань', district: prop.district,
        total_area: area_value, land_area: land_value,
        rooms: prop.rooms, floor: prop.floor, total_floors: prop.total_floors,
        building_year: prop.building_year, building_type: prop.building_type,
        property_condition: CONDITION_TO_PV.fetch(prop.condition.to_s, prop.condition.to_s),
        estimated_price: prop.price,
        metro_station: prop.metro_station, metro_distance: prop.metro_distance,
        evaluation_data: {
          'source' => 'chat_bot',
          'source_property_id' => prop.id,
          'source_property_slug' => prop.slug,
          'source_price_at_capture' => prop.price&.to_s,
          'source_captured_at' => Time.current.iso8601
        }
      )
    end
  end
end
