# frozen_string_literal: true

module ChatTools
  # Передача запроса на оценку специалисту (issue #176, часть 3).
  # Вызывается ботом ПОСЛЕ estimate_property_valuation, когда посетитель
  # согласился передать запрос специалисту и назвал имя + телефон.
  #
  # Создаёт Inquiry типа evaluation с параметрами объекта и ориентировкой
  # (агрегат по похожим оценкам специалистов, сохранённый в
  # PropertyValuation#evaluation_data тулом оценки). Стандартный
  # Inquiry#push_to_work_bot → Lead::Intake (source site_valuation)
  # → Telegram::WorkBot::LeadAnnouncer публикует карточку сотрудникам
  # в топик #ОЦЕНКА (auto_route в config/telegram_topics.yml).
  #
  # Посетителю возвращаем только подтверждение — никаких данных чужих
  # оценок, та же гигиена, что в EstimatePropertyValuation.
  module RequestSpecialistEvaluation
    REQUIRED = %w[name phone].freeze
    SUPPORTED_TYPES = %w[apartment house land commercial garage room].freeze

    # Idempotency: LLM может вызвать тул повторно в одном диалоге —
    # не плодим дубли Inquiry за тем же телефоном (зеркало QualifyLead).
    DEDUPE_WINDOW = 5.minutes

    # Меньше похожих оценок — ориентир по ним не показываем, честно
    # фолбэкаемся на экспресс-оценку (правило N ≥ 3 из issue #176).
    MIN_ORIENT_COUNT = 3

    def self.schema
      {
        type: 'function',
        function: {
          name: 'request_specialist_evaluation',
          description: <<~DESC.strip,
            Передаёт запрос на оценку специалисту АН «Виктори». Создаёт
            заявку — сотрудники получат карточку в рабочем Telegram-чате
            и свяжутся с клиентом.

            Вызывай ТОЛЬКО когда пользователь ЯВНО согласился передать
            запрос специалисту («да, передайте», «хочу точную оценку»,
            «оставлю телефон») и назвал имя и телефон. Обычно — после
            estimate_property_valuation в этом же диалоге: тогда передай
            valuation_token из ответа тула оценки, чтобы специалист увидел
            параметры объекта и ориентир по похожим оценкам.

            Если имени или телефона ещё нет — сначала спроси их в диалоге,
            НЕ вызывай тул. Не вызывай без согласия пользователя.
          DESC
          parameters: {
            type: 'object',
            required: REQUIRED,
            properties: {
              name:            { type: 'string', description: 'Имя клиента' },
              phone:           { type: 'string', description: 'Телефон клиента, например +79001234567' },
              email:           { type: 'string' },
              valuation_token: { type: 'string', description: 'token из ответа estimate_property_valuation этого диалога' },
              property_type:   { type: 'string', enum: SUPPORTED_TYPES },
              address:         { type: 'string' },
              city:            { type: 'string' },
              total_area:      { type: 'number' },
              rooms:           { type: 'integer' },
              message:         { type: 'string', description: 'Комментарий/пожелание клиента своими словами' }
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

      phone = args['phone'].to_s.strip
      name  = args['name'].to_s.strip

      existing = find_recent_duplicate(phone)
      return duplicate_response(existing) if existing

      pv       = find_valuation(args['valuation_token'])
      similar  = extract_similar(pv)
      orientation = orientation_line(pv, similar)

      inquiry = Inquiry.create!(
        name:         name.truncate(100),
        phone:        phone,
        email:        args['email'].to_s.strip.presence,
        inquiry_type: 'evaluation',
        priority:     'normal',
        source:       'site_chatbot',
        message:      build_summary(args, orientation, pv).truncate(2000),
        metadata:     {
          name:        name,
          phone:       phone,
          summary:     orientation.presence || 'Запрос на оценку из чат-бота сайта',
          # 🔵 EXPRESS-бейдж в TG-карточке (см. LeadAnnouncer#format_card)
          service_type: 'express',
          property_valuation_token: pv&.token,
          similar_valuations:       similar
        }.compact
      )

      {
        success:     true,
        inquiry_id:  inquiry.id,
        orientation: orientation,
        message:     'Заявка передана специалистам — свяжутся с клиентом в рабочее время.'
      }
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[ChatTools::RequestSpecialistEvaluation] Inquiry create failed: #{e.message}")
      { error: 'inquiry_failed', message: e.message.to_s.truncate(160) }
    end

    def self.missing_fields_response(missing)
      hints = { 'name' => 'имя клиента', 'phone' => 'телефон клиента' }
      {
        error:   'missing_fields',
        missing: missing,
        message: "Не хватает данных: #{missing.map { |k| hints[k] || k }.join(', ')}. Уточи у пользователя и вызови тул повторно."
      }
    end

    def self.find_recent_duplicate(phone)
      suffix = phone.gsub(/\D/, '').last(10)
      return nil if suffix.length < 10

      Inquiry.where(inquiry_type: :evaluation)
             .where('phone LIKE ?', "%#{suffix}")
             .where('created_at > ?', DEDUPE_WINDOW.ago)
             .order(created_at: :desc)
             .first
    end

    def self.duplicate_response(inquiry)
      {
        success:    true,
        inquiry_id: inquiry.id,
        duplicate:  true,
        message:    'Заявка по этому телефону уже создана несколько минут назад — дубль не нужен.'
      }
    end

    def self.find_valuation(token)
      return nil if token.to_s.strip.empty?

      PropertyValuation.find_by(token: token.to_s.strip)
    end

    # Агрегат по похожим оценкам, сохранённый EstimatePropertyValuation в
    # evaluation_data (jsonb → ключи строки после reload).
    def self.extract_similar(pv)
      data = pv&.evaluation_data
      return nil unless data.is_a?(Hash)

      similar = data['similar_valuations'] || data[:similar_valuations]
      similar.is_a?(Hash) ? similar : nil
    end

    def self.orientation_line(pv, similar)
      count  = similar&.[](:count)  || similar&.[]('count')
      median = similar&.[](:median_price) || similar&.[]('median_price')

      if similar.nil?
        # Инфраструктурный сбой SimilarValuationsFinder (nil) — НЕ «найдено: 0»:
        # без числа похожих оценок, честный нейтральный экспресс-ориентир.
        express_line(pv)
      elsif count.to_i >= MIN_ORIENT_COUNT && median.to_i.positive?
        min = similar[:min_price] || similar['min_price']
        max = similar[:max_price] || similar['max_price']
        format('Ориентир по %d похожим оценкам наших специалистов: ~%s ' \
               '(вилка %s–%s).',
               count.to_i,
               Valuations::PriceFormatter.format_rub(median),
               Valuations::PriceFormatter.format_rub(min),
               Valuations::PriceFormatter.format_rub(max))
      elsif pv&.estimated_price.to_i.positive?
        format('Похожих оценок мало (найдено: %d) — ориентир по экспресс-оценке: ~%s.',
               count.to_i,
               Valuations::PriceFormatter.format_rub(pv.estimated_price))
      end
    end

    def self.express_line(pv)
      return nil unless pv&.estimated_price.to_i.positive?

      format('Ориентир по экспресс-оценке: ~%s.',
             Valuations::PriceFormatter.format_rub(pv.estimated_price))
    end

    # Параметры объекта берём из аргументов тула; при вызове только с
    # valuation_token (LLM не продублировал параметры) — fallback к
    # данным найденной PropertyValuation, чтобы сотрудник видел объект.
    def self.build_summary(args, orientation, pv = nil)
      bits = ['Запрос на оценку из чат-бота сайта.']
      object = []
      object << (args['property_type'].presence || pv&.property_type) if args['property_type'].present? || pv&.property_type.present?
      object << (args['city'].presence || pv&.city) if args['city'].present? || pv&.city.present?
      object << (args['address'].presence || pv&.address) if args['address'].present? || pv&.address.present?
      area_bit = area_display(args, pv)
      object << area_bit if area_bit.present?
      rooms = args['rooms'].to_i.positive? ? args['rooms'].to_i : pv&.rooms.to_i
      object << "#{rooms}-комн" if rooms.positive?
      bits << "Объект: #{object.join(', ')}." if object.any?
      bits << orientation if orientation.present?
      bits << "Комментарий клиента: #{args['message'].to_s.strip}" if args['message'].to_s.strip.present?
      bits.join(' ')
    end

    # Площадь. При valuation_token LLM часто дублирует параметры оценки: для
    # участка total_area в аргументах — это СОТКИ (schema
    # estimate_property_valuation), а в pv значение уже нормализовано
    # (total_area — м², land_area — сотки) — смотреть «8 сот.» как «8 м²»
    # нельзя (нит-пик ревью #206). Поэтому при pv приоритет у его
    # нормализованных значений; raw-аргументы — только без pv.
    def self.area_display(args, pv)
      land = args['property_type'].to_s == 'land' || pv&.property_type == 'land'
      return format_area(pv.land_area, 'сот.') if pv&.land_area.to_f.positive?
      return format_area(pv.total_area, 'м²') if pv&.total_area.to_f.positive?
      return format_area(args['total_area'], 'сот.') if land && args['total_area'].to_f.positive?
      return format_area(args['total_area'], 'м²') if args['total_area'].to_f.positive?

      nil
    end

    # 54.0 → «54», 8.5 → «8.5» — дробная площадь не обрезается через to_i
    # (нит-пик ревью #206).
    def self.format_area(value, unit)
      number = value.to_f
      text = (number % 1).zero? ? number.to_i.to_s : number.round(1).to_s
      "#{text} #{unit}"
    end
  end
end
