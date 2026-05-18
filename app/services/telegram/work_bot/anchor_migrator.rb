# frozen_string_literal: true

module Telegram
  module WorkBot
    # Перемещение якорной карточки лида между топиками рабочего чата.
    #
    # Сценарий: руководитель кликает [КВАРТИРЫ] в #ДИСПЕТЧЕРСКОЙ → бот удаляет
    # старую карточку в General-топике и постит новую в #КВАРТИРЫ (thread_id=17).
    # История миграций сохраняется в LeadEvent.metadata['routing_history'] —
    # для аудита кто, когда и из какого топика перевёл.
    #
    # Бот может удалять СВОИ сообщения без admin-прав (carточка — это его сообщение).
    # 400-ошибка от Telegram (старое сообщение уже удалено) трактуется как идемпотентность.
    class AnchorMigrator
      def initialize(lead_event, target_topic_key, actor:, client: Telegram::Client.new)
        @lead         = lead_event
        @target_key   = target_topic_key.to_s
        @actor        = actor
        @client       = client
      end

      # @return [Boolean] true если миграция произошла, false если skipped
      def call
        return log_skip('invalid target topic_key') unless valid_target?
        return log_skip('already at target topic')  if @lead.anchor_topic_key == @target_key

        @lead.with_lock do
          delete_old_anchor
          new_msg = LeadAnnouncer.new(@lead, client: @client).repost_to(@target_key)
          return false if new_msg.nil? # send_card вернул nil — target_topic_key без thread_id и не General

          @lead.update!(
            anchor_thread_id: Telegram::TopicRegistry.thread_id(@target_key),
            anchor_message_id: new_msg['message_id'],
            anchor_topic_key: @target_key,
            metadata: merged_metadata
          )
        end

        push_note_to_crm
        true
      end

      private

      def valid_target?
        Telegram::TopicRegistry.valid_key?(@target_key)
      end

      def delete_old_anchor
        return if @lead.anchor_message_id.blank?

        @client.delete_message(
          chat_id: @lead.tg_chat_id,
          message_id: @lead.anchor_message_id
        )
      rescue Telegram::Client::Error => e
        # 400 «message to delete not found» — старая карточка уже удалена; идемпотентно.
        Rails.logger.warn("[AnchorMigrator] delete failed (ok if idempotent): #{e.message}")
      end

      def merged_metadata
        meta = (@lead.metadata || {}).deep_dup
        # Phase 12 Iter 39 — cap routing_history через LeadEvent#append_history
        # (HISTORY_DEFAULT_CAPS['routing_history'] = 20). Anti-bloat для лидов
        # с frequent re-routing (manager A → B → A → C сценарии).
        meta['routing_history'] = @lead.append_history(
          key: 'routing_history',
          entry: {
            'at' => Time.current.iso8601,
            'from' => @lead.anchor_topic_key,
            'to' => @target_key,
            'by' => @actor.tg_username
          }
        )
        meta
      end

      def push_note_to_crm
        crm_id = @lead.lead_ref.try(:crm_id)
        return if crm_id.blank?

        topnlab = Topnlab::Client.new
        title   = Telegram::TopicRegistry.title(@target_key)
        text    = "Маршрутизирован в ##{title} руководителем @#{@actor.tg_username} (#{Formatters::DateFormat.fmt_dt(Time.current)})"

        begin
          topnlab.set_note(
            id: crm_id.to_i,
            type: 'order',
            note: text,
            user_id: @actor.topnlab_user_id || ENV.fetch('TOPNLAB_FALLBACK_USER_ID', nil)
          )
        rescue StandardError => e
          # CRM-нота — best-effort; миграция в TG уже произошла.
          Rails.logger.warn("[AnchorMigrator] CRM note push failed: #{e.class}: #{e.message}")
        end

        # Phase 3 — обновляем fc_tg_topic_key чтобы в CRM было видно текущий якорь.
        begin
          topnlab.patch_entity(id: crm_id.to_i, type: 'order', fields: { fc_tg_topic_key: @target_key })
        rescue StandardError => e
          Rails.logger.warn("[AnchorMigrator] patch_entity fc_tg_topic_key failed: #{e.class}: #{e.message}")
        end
      end

      def log_skip(reason)
        Rails.logger.info("[AnchorMigrator] skip lead=#{@lead.id} → #{@target_key}: #{reason}")
        false
      end
    end
  end
end
