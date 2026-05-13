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
      STAGE_EMOJI = {
        'new'           => '🆕',
        'first_contact' => '📞',
        'show'          => '🏠',
        'contract'      => '📄',
        'deal'          => '🤝',
        'closed_won'    => '✅',
        'closed_lost'   => '❌'
      }.freeze

      def initialize(lead_event, client: Telegram::Client.new)
        @lead = lead_event
        @client = client
      end

      def call
        topic_key = resolve_target_topic
        is_general = Telegram::TopicRegistry.general_topic?(topic_key)
        thread_id  = Telegram::TopicRegistry.thread_id(topic_key)

        # General-топик не имеет thread_id (пишем в корень группы). Для всех
        # остальных без discovered thread_id — пропускаем с warning.
        unless thread_id || is_general
          Rails.logger.warn("[LeadAnnouncer] no thread_id for ##{topic_key} — skipping")
          return false
        end

        result = @client.send_message(
          format_card,
          chat_id: Telegram::TopicRegistry.chat_id,
          message_thread_id: thread_id,   # nil для General — Telegram::Client опускает параметр
          reply_markup: routing_keyboard_for(topic_key),
          parse_mode: 'HTML'
        )

        @lead.update!(
          anchor_thread_id:       thread_id,
          anchor_message_id:      result['message_id'],
          anchor_topic_key:       topic_key,
          dispatcher_message_id:  (topic_key == 'dispatcher' ? result['message_id'] : nil)
        )
        true
      end

      private

      # Если у lead.source есть auto_route в YAML — кладём сразу в специализацию.
      # Иначе — в ДИСПЕТЧЕРСКУЮ.
      def resolve_target_topic
        Telegram::TopicRegistry.auto_route_for(@lead.source) || 'dispatcher'
      end

      def format_card
        meta = @lead.metadata || {}
        lines = []
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
          'site_form'      => 'сайт-форма',
          'site_valuation' => 'сайт-оценка',
          'site_mortgage'  => 'сайт-ипотека',
          'tg_dm'          => 'DM боту',
          'manual'         => 'ручной /lead',
          'crm_webhook'    => 'CRM (Topnlab)'
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
    end
  end
end
