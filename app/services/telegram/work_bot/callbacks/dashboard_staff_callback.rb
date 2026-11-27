# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Issue #277 — callback'и карточки сотрудника. Вызывается из
      # DashboardDrillCallback (ветка 'staff' с числовым id), args — сегменты
      # после 'dashboard:staff:':
      #   [<id>]                              — карточка (страница списка = 1)
      #   [<id>, <page>]                      — карточка + страница для «Назад»
      #   [<id>, <page>, <action>[, <param>]] — действие; без page — [<id>, <action>]
      #
      # Действия (только role=admin бота): edit / role / setrole:<role> /
      # assignable / status / status_confirm. Не-admin получает вежливый
      # отказ без изменений — даже при прямом вызове edit-callback'а.
      class DashboardStaffCallback < Base
        manager_only

        ACTIONS = %w[edit role setrole assignable status status_confirm].freeze
        SELF_GUARD_ACTIONS = %w[setrole status status_confirm].freeze

        def handle
          staff = TelegramUser.find_by(id: @args[0])
          return ack('⚠️ Сотрудник не найден.', alert: true) if staff.nil?

          page, action, param = parse
          return ack('⚠️ Неизвестное действие.', alert: true) if action && !ACTIONS.include?(action)
          return ack('🚫 Редактирование карточки — только для admin.', alert: true) if action && !tg_user.role_admin?
          if SELF_GUARD_ACTIONS.include?(action) && staff.id == tg_user.id
            return ack('🚫 Себе роль/статус не меняем — попроси другого admin.', alert: true)
          end

          dispatch(staff, page, action, param)
        end

        private

        # page — числовой сегмент сразу после id; без него действие идёт
        # первым (legacy-формат dashboard:staff:<id>:<action>).
        def parse
          rest = @args[1..] || []
          if rest[0].to_s.match?(/\A\d+\z/)
            [DashboardPagination.normalize_page(rest[0]), rest[1].presence, rest[2].presence]
          else
            [1, rest[0].presence, rest[1].presence]
          end
        end

        def dispatch(staff, page, action, param)
          case action
          when nil              then render(staff, page, :view)
          when 'edit'           then render(staff, page, :edit)
          when 'role'           then render(staff, page, :role)
          when 'setrole'        then apply_role(staff, page, param)
          when 'assignable'     then apply_assignable(staff, page)
          when 'status'         then render(staff, page, :status_confirm)
          when 'status_confirm' then apply_status(staff, page)
          end
        end

        def apply_role(staff, page, role)
          return ack('⚠️ Неизвестная роль.', alert: true) unless TelegramUser.roles.key?(role)

          # is_manager синхронно с role (как /promote): иначе legacy-гейты
          # (manager_only по boolean) рассинхронизируются с enum-ролью.
          staff.update!(role: role, is_manager: %w[manager director admin].include?(role))
          sync_menu(staff)
          render(staff, page, :edit, notice: "✅ Роль обновлена: #{role}")
        end

        def apply_assignable(staff, page)
          staff.update!(assignable: !staff.assignable)
          notice = staff.assignable ? "✅ #{staff.mention} снова в подборе" : "🚫 #{staff.mention} убран из подбора"
          render(staff, page, :edit, notice: notice)
        end

        def apply_status(staff, page)
          notice = if staff.status == 'active'
                     staff.update!(status: 'inactive', assignable: false)
                     "🔒 #{staff.mention} деактивирован"
                   else
                     staff.update!(status: 'active')
                     "▶️ #{staff.mention} активирован"
                   end
          sync_menu(staff)
          render(staff, page, :edit, notice: notice)
        end

        def render(staff, page, mode, notice: nil)
          result = DashboardStaffCard.new(staff: staff, admin_viewer: tg_user.role_admin?,
                                          from_page: page, mode: mode).call
          text = notice ? "#{notice}\n\n#{result.text}" : result.text
          edit(text, result.keyboard)
          ack(notice)
        end

        def edit(text, markup)
          chat_id = callback_query.dig('message', 'chat', 'id')
          message_id = callback_query.dig('message', 'message_id')
          return if chat_id.blank? || message_id.blank?

          client.edit_message_text(text, chat_id: chat_id, message_id: message_id,
                                          reply_markup: markup, parse_mode: 'HTML')
        rescue ::Telegram::Client::Error => e
          Rails.logger.warn("[DashboardStaffCallback#edit] #{e.message}")
        end

        # Как в /promote и /deactivate: после смены роли/статуса — реактивный
        # refresh native /-меню в DM сотрудника. Soft-fail.
        def sync_menu(staff)
          Telegram::WorkBot::CommandsMenuSync.new.sync_for_user!(staff.reload)
        rescue StandardError => e
          Rails.logger.warn("[CommandsMenuSync] staff card sync skip for tg_user=#{staff.id}: #{e.class} #{e.message}")
        end
      end
    end
  end
end
