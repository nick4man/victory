# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 11 Iter 28 — `/resume_batch <id>` — переоткрыть expired/cancelled
      # TaskBatch и снова показать preview с inline-кнопками.
      #
      # Зачем: до этого фикса если Оксана не успела подтвердить голосовой пакет
      # в течение 1 часа (отвлеклась/устала), TaskBatchExpiryJob помечал expired.
      # Восстановление требовало rails console — а голосовое сообщение и
      # parsed_payload пропали из её внимания.
      #
      # Fix: director-only /resume_batch — статус 'expired'|'cancelled' →
      # 'pending_confirm', сбрасывает confirmed_at/cancelled_at/expired_at,
      # пересоздаёт preview через TaskBatchConfirmer. Бот заново шлёт preview
      # с inline-кнопками — теперь Оксана может подтвердить/отменить.
      #
      # Окно reopen — 24 часа (REOPEN_WINDOW). Дальше — context устаревший,
      # пусть Оксана пере-наговорит.
      #
      # Гарантии:
      #   • Director-only (voice intake — её привилегия)
      #   • Только статус !pending_confirm — иначе no-op
      #   • created_by должен быть тем же кто resume'ит (нельзя resume'ить
      #     чужой батч — privacy + audit-trail)
      #   • Окно 24h
      class ResumeBatch < Base
        director_only

        REOPEN_WINDOW = 24.hours

        def handle
          batch_id = args.split(/\s+/).first.to_i
          return reply('Формат: <code>/resume_batch 42</code>') if batch_id.zero?

          batch = ::TaskBatch.find_by(id: batch_id)
          return reply("⚠️ TaskBatch ##{batch_id} не найден.") if batch.nil?

          if batch.created_by_id != tg_user.id
            return reply("🚫 TaskBatch ##{batch.id} был создан #{batch.created_by&.mention} — " \
                         'resume может только создатель.')
          end

          if batch.status_pending_confirm?
            return reply("ℹ️ TaskBatch ##{batch.id} уже в pending_confirm. Проверь свой DM.")
          end

          if batch.status_confirmed?
            return reply("⚠️ TaskBatch ##{batch.id} уже подтверждён " \
                         "(#{batch.confirmed_at&.strftime('%d.%m.%y %H:%M')}). " \
                         'Resume невозможен — задачи уже разосланы. Создай новый голосом.')
          end

          # Окно — для cancelled берём cancelled_at, для expired — expired_at
          closed_at = batch.expired_at || batch.cancelled_at || batch.updated_at
          if closed_at && closed_at < REOPEN_WINDOW.ago
            return reply("⚠️ TaskBatch ##{batch.id} закрыт " \
                         "#{closed_at.strftime('%d.%m.%y %H:%M')} — более 24ч назад. " \
                         'Context устарел, пере-наговори голосом.')
          end

          ::TaskBatch.transaction do
            batch.assign_attributes(
              status: 'pending_confirm',
              expired_at: nil,
              cancelled_at: nil,
              preview_message_id: nil,
              preview_chat_id: nil
            )
            batch.save!
          end

          # Перепоказать preview — TaskBatchConfirmer создаст новое сообщение
          # и обновит preview_message_id в БД.
          Telegram::WorkBot::TaskBatchConfirmer.new(batch: batch, client: @client).call

          reply("🔄 TaskBatch ##{batch.id} переоткрыт — проверь preview в DM.")
        end
      end
    end
  end
end
