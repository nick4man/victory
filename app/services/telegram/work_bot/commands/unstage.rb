# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/unstage` — отмена последнего stage transition. Reply на якорь
      # карточки лида → откатывает на previous_stage из stage_history.
      #
      # Use-case: агент случайно нажал /stage показ вместо /stage контакт,
      # OR director видит ошибку и просит rollback. Без этой команды
      # единственный путь — manual SQL или /stage обратно (но потеряем
      # original first_contact_at если возвращаемся с 'first_contact').
      #
      # Logic:
      #   1. Reply на anchor → find lead
      #   2. Check stage_history.last — если пусто, отказ
      #   3. Pop last entry → set current_stage = entry['from']
      #   4. ВАЖНО: НЕ reset closed_at / first_contact_at — это history,
      #      пусть остаётся. (Если откатываем с closed_lost — current_stage
      #      становится previous, но lead остаётся «когда-то был closed».
      #      Это intentional: full undo требует отдельной команды /reopen.)
      #
      # Auth: assignee лида OR manager+.
      # Audit: append unstage entry в stage_history с marker 'unstage'.
      class Unstage < Base
        def handle
          lead = find_lead_via_reply
          return reply('⚠️ Команда должна быть reply на якорную карточку лида.') unless lead
          return reply("🚫 Откат стадии — только assignee или manager.") unless assignee_or_manager?(lead)

          history = Array(lead.metadata['stage_history'])
          if history.empty?
            return reply('⚠️ История переходов пуста — откатывать нечего.')
          end

          last_entry = history.last
          previous_stage = last_entry['from']
          current_stage  = lead.current_stage

          if previous_stage.blank? || previous_stage == current_stage
            return reply('⚠️ Не удалось определить предыдущую стадию (history corrupt).')
          end

          # Append unstage marker (audit-trail). НЕ removable — это
          # forensic data, кто и когда откатил.
          new_history = lead.append_history(
            key: 'stage_history',
            entry: {
              'at' => Time.current.iso8601,
              'from' => current_stage,
              'to' => previous_stage,
              'by' => tg_user&.mention || 'system',
              'unstage' => true
            }
          )

          lead.update!(
            current_stage: previous_stage,
            metadata: lead.metadata.merge('stage_history' => new_history)
          )

          # Anchor card update — текущая stage в эмодзи перерисовывается.
          # Reuse LeadStageTransition update_anchor_card! если public,
          # либо просто пишем reply и оставляем anchor refresh на next
          # routine sync. Для MVP — текстовый ack.
          reply("↩️ Откат: <b>#{current_stage}</b> → <b>#{previous_stage}</b>\n" \
                "Если ошиблись повторно — /stage <правильная стадия>.")
        end

        private

        def find_lead_via_reply
          reply_to = message['reply_to_message']
          return nil unless reply_to
          LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
        end
      end
    end
  end
end
