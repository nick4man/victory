# frozen_string_literal: true

module Telegram
  module WorkBot
    module Sla
      # Отправляет SLA-уведомление о просроченном лиде в #ДИСПЕТЧЕРСКОЙ +
      # DM назначенному агенту. Дедуп через `LeadEvent.metadata['last_sla_ping_at']`
      # — не повторяем чаще раз в 30 минут (даже если cron каждые 5 мин).
      #
      # Quiet hours (21:00-07:00 Moscow) обрабатываются на уровне `PingJob`
      # (там же defer через perform_at). Этот сервис только формирует и шлёт.
      #
      # @param lead [LeadEvent]
      # @param kind [Symbol] :first_contact_overdue
      class PingService
        DEDUP_WINDOW = 30.minutes

        def initialize(lead, kind:, client: Telegram::Client.new)
          @lead   = lead
          @kind   = kind
          @client = client
        end

        # @return [Boolean] true если ping отправлен, false при skip (дедуп или нет данных)
        def call
          return skip('already pinged recently') if recently_pinged?
          return skip('no assignee')             if @lead.assigned_to.blank?
          return skip('lead closed')             if @lead.closed_at.present?

          post_in_dispatcher
          dm_assignee
          mark_pinged!
          true
        end

        private

        def recently_pinged?
          last = @lead.metadata['last_sla_ping_at']
          return false if last.blank?

          Time.zone.parse(last) > DEDUP_WINDOW.ago
        rescue ArgumentError
          false
        end

        def mark_pinged!
          @lead.update!(metadata: @lead.metadata.merge('last_sla_ping_at' => Time.current.iso8601,
                                                       'last_sla_kind' => @kind.to_s))
        end

        # Пинг в #ДИСПЕТЧЕРСКОЙ — там собирается весь оперативный pulse.
        def post_in_dispatcher
          dispatcher_thread_id = Telegram::TopicRegistry.thread_id('dispatcher')
          # dispatcher — General-топик, thread_id отсутствует — пишем в корень группы.
          @client.send_message(
            dispatcher_text,
            chat_id: @lead.tg_chat_id,
            message_thread_id: dispatcher_thread_id,
            parse_mode: 'HTML'
          )
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[Sla::PingService] dispatcher post failed: #{e.message}")
        end

        def dm_assignee
          chat_id = @lead.assigned_to.dm_chat_id || @lead.assigned_to.tg_user_id
          return if chat_id.blank?

          @client.send_message(dm_text, chat_id: chat_id, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[Sla::PingService] DM to #{@lead.assigned_to.mention} failed: #{e.message}")
        end

        def dispatcher_text
          mins = ((Time.current - @lead.assigned_at) / 60).to_i
          name = @lead.metadata['name'].to_s.presence || 'клиент'
          topic = Telegram::TopicRegistry.title(@lead.anchor_topic_key) || @lead.anchor_topic_key
          "⏰ #{@lead.assigned_to.mention}, #{mins} мин с назначения — нет first_contact " \
            "по лиду <b>#{escape(name)}</b> (##{escape(topic)}). " \
            "<a href=\"#{@lead.anchor_url}\">Открыть карточку</a>"
        end

        def dm_text
          name = @lead.metadata['name'].to_s.presence || 'клиент'
          mins = ((Time.current - @lead.assigned_at) / 60).to_i
          "⏰ Напоминание: лид <b>#{escape(name)}</b> ждёт первого контакта " \
            "(#{mins} мин с назначения). #{@lead.anchor_url}"
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end

        def skip(reason)
          Rails.logger.info("[Sla::PingService] skip lead=#{@lead.id}: #{reason}")
          false
        end
      end
    end
  end
end
