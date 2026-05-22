# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Назначение лида агенту.
      #   • В group: `/assign @user` reply на якорную карточку
      #   • В DM (Phase 15): `/assign <lead_id> @user` — explicit lead_id первым
      # Manager-only.
      class Assign < Base
        manager_only

        def handle
          # Phase 15 — resolve_lead! сначала «съест» lead_id если он есть в @args.
          # После этого @args содержит только username.
          lead = resolve_lead!
          return reply(lead_not_found_hint('assign')) unless lead

          username = @args.to_s.strip
          return reply('Формат: <code>/assign @username</code> (reply на якорь) ИЛИ ' \
                       '<code>/assign &lt;lead_id&gt; @username</code> в DM.') if username.blank?

          # rubocop:disable Rails/DynamicFindBy -- custom class method, не Rails dynamic finder
          assignee = TelegramUser.find_by_username(username)
          # rubocop:enable Rails/DynamicFindBy
          return reply("⚠️ Сотрудник #{username} не зарегистрирован. Попроси его написать /whoami.") unless assignee

          result = Telegram::WorkBot::LeadAssignment.new(lead, assignee: assignee, actor: tg_user, client: client).call
          if result.success?
            msg = "✅ Лид ##{lead.id} → #{assignee.mention}"
            msg += " <i>(#{result.error_message})</i>" if result.error_message
            reply(msg)
          else
            reply("⚠️ #{result.error_message}")
          end
        end
      end
    end
  end
end
