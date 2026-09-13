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
      #
      # Без даты и текста (`/task`, `/task 87`, reply `/task`) команда не
      # отвечает форматом, а открывает мастер в личке — аргументы печатать
      # не нужно. См. Wizard::TaskFlow.
      class Task < Base
        def handle
          # Phase 15 — resolve_lead! «съест» lead_id ЕСЛИ 1-й arg число.
          # После resolve_lead! @args = «dd.MM.yy <текст>» (как и было в group).
          typed_id = @args.to_s[/\A\d+/]
          lead = resolve_lead!
          return open_wizard('task', lead, seed_id: typed_id) if @args.blank?
          return reply(lead_not_found_hint('task 15.05.26 текст')) unless lead

          parts = @args.to_s.strip.split(/\s+/, 2)
          date_token = parts[0]
          title = parts[1].to_s.strip
          return reply('Формат: <code>/task &lt;dd.MM.yy&gt; &lt;текст&gt;</code> (reply) ИЛИ ' \
                       '<code>/task &lt;lead_id&gt; &lt;dd.MM.yy&gt; &lt;текст&gt;</code> (DM).') if date_token.blank? || title.blank?

          due_date = Formatters::DateFormat.parse(date_token)
          return reply("⚠️ Не понимаю дату <code>#{date_token}</code>. Формат: <code>dd.MM.yy</code> (например, 15.05.26).") unless due_date

          LeadTaskCreator.new(lead, due_date: due_date, title: title, actor: tg_user,
                                    tg_message_id: message['message_id']).call

          reply("📅 Задача создана для лида ##{lead.id}: <b>#{escape_html(title)}</b> · до #{Formatters::DateFormat.fmt(due_date)}")
        end
      end
    end
  end
end
