# frozen_string_literal: true

module Telegram
  module WorkBot
    # Зеркальный тизер в топике #СДЕЛКА — короткое сообщение со ссылкой на
    # якорную карточку лида. Создаётся при переходе в стадии `contract`/`deal`,
    # чтобы все участники финальной фазы видели актуальное состояние пайплайна,
    # но без дублирования всей карточки.
    #
    # message_id тизера сохраняется в LeadEvent.deal_mirror_message_id —
    # повторный вызов идемпотентен (skip если уже есть).
    class DealMirror
      DEAL_TOPIC_KEY = 'deal'

      STAGE_LABELS = {
        'contract' => '📄 Договор',
        'deal' => '🤝 Сделка',
        'closed_won' => '✅ Выиграно',
        'closed_lost' => '❌ Проиграно'
      }.freeze

      def initialize(lead_event, client: Telegram::Client.new)
        @lead = lead_event
        @client = client
      end

      # @return [Boolean] true если тизер запостился, false при skip
      def post
        return log_skip('already mirrored') if @lead.deal_mirror_message_id.present?

        thread_id = Telegram::TopicRegistry.thread_id(DEAL_TOPIC_KEY)
        return log_skip('no thread_id for #СДЕЛКА') if thread_id.blank?

        msg = @client.send_message(
          format_teaser,
          chat_id: @lead.tg_chat_id,
          message_thread_id: thread_id,
          parse_mode: 'HTML',
          disable_web_page_preview: true
        )

        return log_skip('TG returned nil') if msg.blank? || msg['message_id'].blank?

        @lead.update!(deal_mirror_message_id: msg['message_id'])
        true
      end

      private

      def format_teaser
        meta  = @lead.metadata || {}
        name  = escape(meta['name'].to_s.presence || 'клиент')
        label = STAGE_LABELS[@lead.current_stage] || @lead.current_stage
        topic = escape(Telegram::TopicRegistry.title(@lead.anchor_topic_key) || @lead.anchor_topic_key.to_s)

        "#{label} · <b>#{name}</b>\n" \
          "Якорь: ##{topic} · <a href=\"#{@lead.anchor_url}\">открыть карточку</a>\n" \
          "Обновлено: #{Formatters::DateFormat.fmt_dt(Time.current)}"
      end

      def log_skip(reason)
        Rails.logger.info("[DealMirror] skip lead=#{@lead.id}: #{reason}")
        false
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
