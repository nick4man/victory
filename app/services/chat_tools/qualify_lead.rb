# frozen_string_literal: true

module ChatTools
  # Lead qualification scoring tool. LLM extracts intent + параметры из
  # разговора и вызывает qualify_lead — мы computeit priority (normal/
  # high/urgent) на основе 5 signals и optionally create Inquiry с
  # set priority. LeadAnnouncer затем рендерит «⚡ HIGH PRIORITY» badge
  # в TG-карточке (см. telegram/work_bot/lead_announcer.rb:114).
  #
  # Это первый Phase D entry: автоматизация part'и которая раньше
  # требовала agent'а вручную ранжировать каждый лид. Цель — agent
  # видит ranked list, premium вверху, дешёвые внизу.
  #
  # Scoring philosophy: conservative. Высокий bar для 'urgent' (score ≥6),
  # чтобы agents не devaluate'или badge. Без real ML training data —
  # heuristic rules. После 10+ closed deals retune.
  module QualifyLead
    PREMIUM_DISTRICTS = [
      'Центр', 'Солотча', 'Канищево', 'Дашково', 'Театральная',
      'Семчино', 'Михайловское'
    ].freeze

    # Urgency markers (lowercase, substring match)
    URGENCY_HOT  = %w[сейчас срочно немедленно сегодня завтра].freeze
    URGENCY_NEAR = %w[месяц неделя ближайшие квартал].freeze
    URGENCY_FAR  = %w[год позже подумаю когда-нибудь рассматриваю].freeze

    INTENT_TO_INQUIRY_TYPE = {
      'buy'    => 'consultation',
      'sell'   => 'evaluation',
      'rent'   => 'consultation',
      'invest' => 'consultation'
    }.freeze

    # Score → priority enum mapping. Conservative — urgent для score ≥6
    # (premium+timeline+phone all firing).
    PRIORITY_URGENT_THRESHOLD = 6
    PRIORITY_HIGH_THRESHOLD   = 4

    # Idempotency: не создавать duplicate Inquiry если тот же phone+intent
    # уже создан в последние 5 минут (LLM может вызвать tool несколько раз
    # в одном диалоге).
    DEDUPE_WINDOW = 5.minutes

    def self.schema
      {
        type: 'function',
        function: {
          name: 'qualify_lead',
          description: <<~DESC.strip,
            Квалифицирует лид по 5 параметрам и возвращает priority (normal/
            high/urgent) + reasoning. Создаёт Inquiry record если phone и name
            указаны (тогда агенты получат уведомление в TG-группе).

            Вызывай ВНУТРИ беседы когда пользователь явно выражает intent
            покупки/продажи + указал хотя бы 2 параметра (бюджет, район,
            тип, сроки). НЕ вызывай для общих вопросов «опиши район»,
            «какие ставки по ипотеке».

            Scoring: budget × district × timeline × type × phone → enum.
            Premium districts (Центр/Солотча/Канищево/Дашково) и budget
            ≥15M ₽ — главные signals high/urgent priority.

            Возвращает: priority, score (0-10), breakdown, reasoning, inquiry_id?
          DESC
          parameters: {
            type: 'object',
            required: %w[intent],
            properties: {
              intent: {
                type:        'string',
                enum:        %w[buy sell rent invest],
                description: 'Тип запроса клиента (что хочет — купить/продать/арендовать/инвестировать)'
              },
              budget_rub: {
                type:        'integer',
                description: 'Бюджет в рублях (0 если не указан)'
              },
              district: {
                type:        'string',
                description: 'Район Рязани (например Центр, Солотча, Дашково). Пустая строка если не указан.'
              },
              property_type: {
                type:        'string',
                enum:        %w[apartment house land commercial garage room],
                description: 'Тип объекта недвижимости'
              },
              timeline: {
                type:        'string',
                description: 'Сроки клиента (свободный текст: "сейчас", "в течение 3 месяцев", "в этом году" и т.п.)'
              },
              phone: {
                type:        'string',
                description: 'Телефон клиента в формате +71234567890 (опционально, но нужен для создания Inquiry)'
              },
              name: {
                type:        'string',
                description: 'Имя клиента (опционально, но нужен для создания Inquiry)'
              },
              email: {
                type:        'string',
                description: 'Email клиента (опционально)'
              },
              message: {
                type:        'string',
                description: 'Развёрнутое описание запроса от клиента (для контекста агента)'
              }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args = {})
      args = args.to_h.transform_keys(&:to_sym)

      score, breakdown = compute_score(args)
      priority = enum_for(score)
      reasoning = build_reasoning(args, score, priority)

      inquiry = maybe_create_inquiry(args, priority, breakdown, reasoning)

      {
        status:     'ok',
        priority:   priority,
        score:      score,
        breakdown:  breakdown,
        reasoning:  reasoning,
        inquiry_id: inquiry&.id,
        message:    format_message(priority, score, reasoning, inquiry)
      }
    end

    def self.compute_score(args)
      breakdown = {}

      # Budget tier
      budget = args[:budget_rub].to_i
      breakdown[:budget] = case budget
                           when 30_000_000.. then 3
                           when 15_000_000..30_000_000 then 2
                           when 5_000_000..15_000_000 then 1
                           else 0
                           end

      # District tier
      district = args[:district].to_s.strip
      breakdown[:district] = if PREMIUM_DISTRICTS.any? { |d| district.include?(d) }
                               2
                             elsif district.present?
                               1
                             else
                               0
                             end

      # Timeline urgency (case-insensitive substring match)
      timeline = args[:timeline].to_s.downcase
      breakdown[:timeline] = if URGENCY_HOT.any? { |m| timeline.include?(m) }
                               2
                             elsif URGENCY_NEAR.any? { |m| timeline.include?(m) }
                               1
                             elsif URGENCY_FAR.any? { |m| timeline.include?(m) }
                               0
                             else
                               0
                             end

      # Property-type signal (premium types)
      breakdown[:type] = case args[:property_type].to_s
                         when 'house', 'land' then 1
                         else 0
                         end

      # Phone present = readiness signal (готов к контакту)
      breakdown[:phone] = args[:phone].to_s.strip.match?(/\A\+?\d{10,}\z/) ? 1 : 0

      score = breakdown.values.sum
      [score, breakdown]
    end

    def self.enum_for(score)
      return 'urgent' if score >= PRIORITY_URGENT_THRESHOLD
      return 'high'   if score >= PRIORITY_HIGH_THRESHOLD

      'normal'
    end

    def self.build_reasoning(args, score, priority)
      parts = []

      budget = args[:budget_rub].to_i
      if budget >= 15_000_000
        parts << "премиум-сегмент #{(budget / 1_000_000.0).round(1)}М ₽"
      elsif budget.positive?
        parts << "бюджет #{(budget / 1_000_000.0).round(1)}М ₽"
      end

      district = args[:district].to_s.strip
      if PREMIUM_DISTRICTS.any? { |d| district.include?(d) }
        parts << "район #{district} (премиум)"
      elsif district.present?
        parts << "район #{district}"
      end

      timeline = args[:timeline].to_s
      if URGENCY_HOT.any? { |m| timeline.downcase.include?(m) }
        parts << 'готов сейчас'
      elsif URGENCY_NEAR.any? { |m| timeline.downcase.include?(m) }
        parts << 'сроки 1-3 мес'
      elsif URGENCY_FAR.any? { |m| timeline.downcase.include?(m) }
        parts << 'долгосрочно'
      end

      parts << 'телефон оставлен' if args[:phone].to_s.match?(/\A\+?\d{10,}\z/)

      label = case priority
              when 'urgent' then 'горячий лид'
              when 'high'   then 'тёплый лид'
              else               'наблюдаем'
              end

      if parts.empty?
        "#{label} (score #{score}/10)."
      else
        # Только первая буква в верхний регистр — `String#capitalize` ломает
        # «25.0М ₽» → «25.0м ₽» (downcase'ит остаток строки).
        sentence = parts.join(', ')
        sentence = sentence.sub(/\A(\p{L})/) { Regexp.last_match(1).upcase }
        "#{sentence} — #{label} (score #{score}/10)."
      end
    end

    # Создаём Inquiry только если есть phone + name (Inquiry validates обоих
    # presence). Иначе LLM ещё в discovery — пусть продолжает диалог.
    def self.maybe_create_inquiry(args, priority, breakdown, reasoning)
      phone = args[:phone].to_s.strip
      name  = args[:name].to_s.strip
      return nil if phone.blank? || name.blank?

      # Idempotency: skip если recent identical lead (LLM может call tool
      # multiple раз в одном диалоге). Phone normalization — last 10 digits
      # т.к. Inquiry хранит phone в normalized form (без + и форматирования).
      phone_digits = phone.gsub(/\D/, '')
      phone_suffix = phone_digits.last(10)
      if phone_suffix.length == 10
        recent = Inquiry.where('phone LIKE ?', "%#{phone_suffix}").
                 where('created_at > ?', DEDUPE_WINDOW.ago).
                 order(created_at: :desc).first
        return recent if recent
      end

      Inquiry.create!(
        name:          name.truncate(100),
        phone:         phone,
        email:         args[:email].to_s.strip.presence,
        inquiry_type:  INTENT_TO_INQUIRY_TYPE[args[:intent].to_s] || 'consultation',
        priority:      priority,
        source:        'site_chatbot',
        message:       (args[:message].to_s.presence || reasoning).truncate(2000),
        metadata:      {
          intent:        args[:intent].to_s,
          budget_rub:    args[:budget_rub].to_i,
          district:      args[:district].to_s,
          property_type: args[:property_type].to_s,
          timeline:      args[:timeline].to_s,
          score:         breakdown.values.sum,
          breakdown:     breakdown,
          reasoning:     reasoning,
          # Phone/name дублируются в metadata для LeadAnnouncer card —
          # он читает meta['name'] / meta['phone'].
          name:          name,
          phone:         phone,
          priority:      priority,  # LeadAnnouncer reads meta['priority']
          summary:       reasoning
        }
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[QualifyLead] Inquiry create failed: #{e.message}")
      nil
    end

    def self.format_message(priority, score, reasoning, inquiry)
      base = "Лид квалифицирован: #{priority.upcase} (#{score}/10). #{reasoning}"
      base += " Создан Inquiry ##{inquiry.id} — агент свяжется." if inquiry
      base
    end
  end
end
