# frozen_string_literal: true

module Telegram
  module WorkBot
    # Публикует якорную карточку нового лида в Telegram-чате АН.
    #
    # Маршрут публикации:
    #   1. Если у источника есть auto_route (lookup в config/telegram_topics.yml
    #      по auto_route_from) — публикуем сразу в специализированный топик,
    #      минуя ДИСПЕТЧЕРСКУЮ. Пример: заявка с формы оценки → #ОЦЕНКА.
    #   2. Иначе — пишем в ДИСПЕТЧЕРСКУЮ с inline-кнопками маршрутизации
    #      (КВАРТИРЫ / ДОМА / … / ИПОТЕКА / Спам).
    #
    # Возвращает true если карточка опубликована, false при пропуске
    # (например, thread_id ещё не известен — топик не discovered).
    class LeadAnnouncer
      ROUTING_BUTTONS_PER_ROW = 3

      # Re-render card после того как async-задача насытила lead_ref
      # (PropertyValuationJob выдал estimate/range/PDF). Шлёт TG
      # editMessageText на anchor_message_id с обновлённым text. Кнопки
      # routing остаются. Возвращает true/false.
      def self.refresh!(lead_event, client: Telegram::Client.new)
        return false if lead_event.anchor_message_id.blank?

        announcer = new(lead_event, client: client)
        topic_key = lead_event.anchor_topic_key
        client.edit_message_text(
          announcer.format_card_text,
          chat_id: Telegram::TopicRegistry.chat_id,
          message_id: lead_event.anchor_message_id,
          reply_markup: announcer.send(:routing_keyboard_for, topic_key),
          parse_mode: 'HTML'
        )
        true
      rescue StandardError => e
        Rails.logger.warn("[LeadAnnouncer.refresh!] lead=#{lead_event.id} failed: #{e.class} #{e.message.to_s.truncate(160)}")
        false
      end

      STAGE_EMOJI = {
        'new' => '🆕',
        'first_contact' => '📞',
        'show' => '🏠',
        'contract' => '📄',
        'deal' => '🤝',
        'closed_won' => '✅',
        'closed_lost' => '❌'
      }.freeze

      def initialize(lead_event, client: Telegram::Client.new)
        @lead = lead_event
        @client = client
      end

      def call
        topic_key = resolve_target_topic
        result = send_card(topic_key)
        return false if result.nil?

        @lead.update!(
          anchor_thread_id: Telegram::TopicRegistry.thread_id(topic_key),
          anchor_message_id: result['message_id'],
          anchor_topic_key: topic_key,
          dispatcher_message_id: (topic_key == 'dispatcher' ? result['message_id'] : nil)
        )
        true
      end

      # Публичная точка для AnchorMigrator (Phase 2 шаг 4): постит карточку
      # в указанный топик БЕЗ обновления LeadEvent — обновлением занимается
      # сам AnchorMigrator (он же сохраняет routing_history). Возвращает TG
      # message hash либо nil, если у топика нет thread_id и он не General.
      def repost_to(target_topic_key)
        send_card(target_topic_key)
      end

      # Текст карточки — публичный геттер для AnchorMigrator/Stage edit'ов.
      def format_card_text
        format_card
      end

      private

      def send_card(topic_key)
        is_general = Telegram::TopicRegistry.general_topic?(topic_key)
        thread_id  = Telegram::TopicRegistry.thread_id(topic_key)

        # General-топик не имеет thread_id. Для всех остальных без discovered
        # thread_id — пропускаем с warning.
        unless thread_id || is_general
          Rails.logger.warn("[LeadAnnouncer] no thread_id for ##{topic_key} — skipping")
          return nil
        end

        @client.send_message(
          format_card,
          chat_id: Telegram::TopicRegistry.chat_id,
          message_thread_id: thread_id, # nil для General — Telegram::Client опускает параметр
          reply_markup: routing_keyboard_for(topic_key),
          parse_mode: 'HTML'
        )
      end

      # Если у lead.source есть auto_route в YAML — кладём сразу в специализацию.
      # Иначе — в ДИСПЕТЧЕРСКУЮ.
      def resolve_target_topic
        Telegram::TopicRegistry.auto_route_for(@lead.source) || 'dispatcher'
      end

      def format_card
        meta = @lead.metadata || {}
        lines = []
        # Priority badge — high → ⚡, urgent → 🔥 (горячий лид). Inquiry.priority
        # enum normal/high/urgent проводится через Lead::Intake::SiteSource → meta.
        # Returning client (A7 Phase 1) — отдельный badge, показывается параллельно
        # с priority (urgent + returning = два бэджа на одной строке).
        priority_badge = case meta['priority'].to_s
                         when 'urgent' then '🔥 <b>URGENT — горячий лид</b>'
                         when 'high'   then '⚡ <b>HIGH PRIORITY</b>'
                         end
        returning_badge = '🔄 <b>ВОЗВРАТНЫЙ КЛИЕНТ</b>' if meta['returning_client']
        # Service-type badge — какой тип оценки/услуги выбрал клиент в чате
        # после express-валуации (см. ChatTools::QualifyLead). Помогает
        # дежурному быстро понять что нужно делать: CMA-выезд, инвест-аудит,
        # подбор аналогов или это просто express-оценка с формы.
        service_badge = case meta['service_type'].to_s
                        when 'express'    then '🔵 <b>EXPRESS</b>'
                        when 'investment' then '🟣 <b>INVESTMENT AUDIT</b>'
                        when 'cma'        then '🟠 <b>SALE CMA</b>'
                        when 'buyer_scan' then '🟢 <b>BUYER SCAN</b>'
                        end
        badge_line = [priority_badge, returning_badge, service_badge].compact.join(' · ')
        lines << badge_line if badge_line.present?
        lines << "#{stage_icon} <b>Новый лид</b> · #{escape(source_label)}"
        lines << ''
        lines << "👤 #{escape(meta['name'].to_s.presence || '—')}#{phone_suffix(meta['phone'])}"
        lines << "🏷 #{escape(@lead.lead_ref.try(:title).to_s)}" if @lead.lead_ref.respond_to?(:title) && @lead.lead_ref.title.present?
        if meta['summary'].present?
          lines << ''
          lines << escape(meta['summary'].to_s.truncate(500))
        end
        if meta['budget'].present?
          lines << ''
          lines << "💰 #{escape(meta['budget'].to_s)}"
        end

        # Valuation block — when lead_ref is completed PropertyValuation.
        # Это блок добавляется TG editMessageText'ом после того как
        # PropertyValuationJob завершил compute (см. LeadAnnouncer.refresh!
        # + PropertyValuationJob#push_to_lead_card). До completion блок
        # отсутствует, card будет sparser.
        valuation = @lead.lead_ref
        if valuation.is_a?(PropertyValuation) && valuation.try(:completed?) && valuation.estimated_price.present?
          lines << ''
          lines << '📐 <b>Результаты оценки</b>'
          lines << "  · Рыночная: <b>#{escape(fmt_rub(valuation.estimated_price))}</b>"
          if valuation.min_price.present? && valuation.max_price.present?
            lines << "  · Диапазон: #{escape(fmt_rub(valuation.min_price))} – #{escape(fmt_rub(valuation.max_price))}"
          end
          lines << "  · Достоверность: #{((valuation.confidence_level || 0).to_f * 100).round}%" if valuation.confidence_level
          lines << ''
          lines << %(🔗 <a href="#{report_url(valuation)}">Открыть отчёт</a>)
        end

        lines << ''
        lines << "🕐 #{Formatters::DateFormat.fmt_dt(@lead.created_at)}"
        if @lead.assigned_to
          lines << "👤 Назначен: #{escape(@lead.assigned_to.display_name)}"
        end
        lines.join("\n")
      end

      def stage_icon
        STAGE_EMOJI[@lead.current_stage] || '🆕'
      end

      def source_label
        {
          'site_form' => 'сайт-форма',
          'site_valuation' => 'сайт-оценка',
          'site_mortgage' => 'сайт-ипотека',
          'tg_dm' => 'DM боту',
          'manual' => 'ручной /lead',
          'crm_webhook' => 'CRM (Topnlab)'
        }[@lead.source.to_s] || @lead.source.to_s
      end

      def phone_suffix(phone)
        return '' if phone.blank?

        ", #{escape(phone.to_s)}"
      end

      def routing_keyboard_for(topic_key)
        rows = []
        if topic_key == 'dispatcher'
          buttons = Telegram::TopicRegistry.routing_buttons.map do |key|
            { text: Telegram::TopicRegistry.title(key), callback_data: "route:#{@lead.id}:#{key}" }
          end
          buttons.each_slice(ROUTING_BUTTONS_PER_ROW) { |row| rows << row }
        end
        rows << [
          { text: '👤 Назначить', callback_data: "assign:#{@lead.id}" },
          { text: '🚫 Спам',      callback_data: "spam:#{@lead.id}" }
        ]
        { inline_keyboard: rows }
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end

      # Mirror of ExpressReportNotifier#fmt_rub — should ideally extract
      # to shared formatter helper. Keeping duplicate для simplicity пока
      # не появится третий call-site (DRY ratio < 3).
      def fmt_rub(amount)
        return '—' if amount.blank?
        "#{amount.to_i.to_s.reverse.gsub(/(\d{3})/, '\1 ').reverse.strip} ₽"
      end

      def report_url(valuation)
        base = ENV['APP_URL'].presence ||
               (defined?(AgencyInfo) ? AgencyInfo::WEBSITE_URL : 'https://victory62.org')
        "#{base}/valuations/#{valuation.token}/result"
      end
    end
  end
end
