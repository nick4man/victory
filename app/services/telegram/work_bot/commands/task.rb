# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/task <dd.MM.yy> <текст>` reply на якорную карточку — создаёт локальный
      # Task и пробрасывает дедлайн в Topnlab fc_next_action_at кастомное поле
      # (через patch_entity). Топик задачи (`realty`/`order`) определяется
      # по типу lead_ref.crm_id: для Inquiry/BuyerOrder → 'order'.
      #
      # Формат даты — строго dd.MM.yy (см. Formatters::DateFormat).
      class Task < Base
        def handle
          parts = args.to_s.strip.split(/\s+/, 2)
          date_token = parts[0]
          title = parts[1].to_s.strip
          return reply('Формат: <code>/task &lt;dd.MM.yy&gt; &lt;текст задачи&gt;</code> (reply на якорную карточку).') if date_token.blank? || title.blank?

          due_date = Formatters::DateFormat.parse(date_token)
          return reply("⚠️ Не понимаю дату <code>#{date_token}</code>. Формат: <code>dd.MM.yy</code> (например, 15.05.26).") unless due_date

          lead = find_lead_via_reply
          return reply('⚠️ Команда должна быть reply на якорную карточку лида.') unless lead

          build_task!(lead, due_date, title)
          push_due_to_crm(lead, due_date)

          reply("📅 Задача создана: <b>#{escape(title)}</b> · до #{Formatters::DateFormat.fmt(due_date)}")
        end

        private

        def find_lead_via_reply
          reply_to = message['reply_to_message']
          return nil unless reply_to

          LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
        end

        def build_task!(lead, due_date, title)
          ::Task.create!(
            lead_event: lead,
            assignee: lead.assigned_to || tg_user,
            created_by: tg_user,
            title: title.to_s[0, 255],
            due_at: due_date.in_time_zone.end_of_day,
            topnlab_id: lead.lead_ref.try(:crm_id).to_i.nonzero?,
            topnlab_type: 'order',
            tg_message_id: message['message_id']
          )
        end

        def push_due_to_crm(lead, due_date)
          crm_id = lead.lead_ref.try(:crm_id)
          return if crm_id.blank?

          Topnlab::Client.new.patch_entity(
            id: crm_id.to_i,
            type: 'order',
            fields: { fc_next_action_at: due_date.in_time_zone.end_of_day.iso8601 }
          )
        rescue StandardError => e
          Rails.logger.warn("[Commands::Task] patch_entity failed: #{e.class}: #{e.message}")
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
