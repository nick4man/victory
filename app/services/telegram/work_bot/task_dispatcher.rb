# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 7.3 — Отправляет DM каждому assignee с его задачами + inline-кнопки
    # [▶ В работе][✅ Выполнено] для multi-modal completion ack.
    #
    # Группирует переданные Tasks по assignee_id, для каждой группы шлёт 1 DM
    # (один pinned message обновляется по ходу выполнения — Phase 7.4 digest).
    # На успешный send → task.notified_at = now.
    #
    # Soft-fail на missing dm_chat_id: пытаемся отправить по tg_user_id (TG
    # примет если юзер когда-либо писал боту). Если 403 — логируем + reply
    # в группу с просьбой агенту написать /start боту.
    #
    # @example
    #   tasks = Task.where(task_batch_id: batch.id)
    #   Telegram::WorkBot::TaskDispatcher.new(tasks: tasks).call
    #   # → каждый assignee получает DM с его задачами + кнопки
    class TaskDispatcher
      KIND_ICON = {
        'call' => '📞',
        'show' => '🏠',
        'document' => '📄',
        'admin' => '⚙️',
        'other' => '📌'
      }.freeze

      PRIORITY_ICON = {
        'urgent' => '🔴',
        'high' => '🟠',
        'normal' => '⚪',
        'low' => '⚫'
      }.freeze

      def initialize(tasks:, client: Telegram::Client.new)
        @tasks  = Array(tasks).compact
        @client = client
      end

      def call
        return :no_tasks if @tasks.empty?

        group_by_assignee.map do |assignee, group|
          dispatch_for(assignee, group)
        end
      end

      private

      def group_by_assignee
        @tasks.group_by(&:assignee).reject { |a, _| a.nil? }
      end

      def dispatch_for(assignee, tasks)
        chat_id = assignee.dm_chat_id || assignee.tg_user_id
        return skip_no_chat(assignee, tasks) if chat_id.blank?

        text   = build_text(assignee, tasks)
        markup = build_keyboard(tasks)

        msg = @client.send_message(text,
                                   chat_id: chat_id,
                                   parse_mode: 'HTML',
                                   reply_markup: markup)

        now = Time.current
        tasks.each { |t| t.update_columns(notified_at: now) }

        { assignee: assignee.mention, count: tasks.size, message_id: msg['message_id'] }
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[TaskDispatcher] DM to #{assignee.mention} failed: #{e.message}")
        { assignee: assignee.mention, count: tasks.size, error: e.message }
      end

      def skip_no_chat(assignee, tasks)
        Rails.logger.warn("[TaskDispatcher] no chat_id for #{assignee.mention}; tasks #{tasks.map(&:id).inspect} not dispatched")
        { assignee: assignee.mention, count: tasks.size, error: 'no chat_id' }
      end

      def build_text(assignee, tasks)
        urgent = tasks.any?(&:priority_urgent?)
        header = "#{'⚡ ' if urgent}🎯 <b>Тебе #{tasks.size} #{plural_tasks(tasks.size)}</b>"

        lines = [header, "Привет, #{escape(assignee.first_name.presence || assignee.tg_username || 'коллега')}!", '']
        tasks.each_with_index do |task, idx|
          lines << format_task(task, idx + 1)
        end
        lines << ''
        lines << "<i>Используй кнопки под сообщением или команду <code>/done #{tasks.first.id}</code>.</i>"
        lines.join("\n")
      end

      def plural_tasks(n)
        # 1 задача / 2-4 задачи / 5+ задач
        rem10 = n % 10
        rem100 = n % 100
        return 'задач' if rem100.between?(11, 14)
        return 'задача' if rem10 == 1
        return 'задачи' if rem10.between?(2, 4)

        'задач'
      end

      def format_task(task, idx)
        kind_icon     = KIND_ICON[task.kind.to_s] || '📌'
        priority_icon = PRIORITY_ICON[task.priority.to_s] || '⚪'
        due_str       = task.due_at ? "до #{task.due_at.strftime('%d.%m.%y %H:%M')}" : 'без срока'
        "<b>#{idx}.</b> #{kind_icon} #{priority_icon} #{escape(task.title)}\n     <i>#{due_str}</i> · <code>/done #{task.id}</code>"
      end

      # Inline-кнопки [▶ В работе #task_id][✅ Выполнено #task_id] для КАЖДОЙ
      # задачи в DM. Один row на задачу. Up to 8 задач — выше делим на batches
      # (TG лимит на reply_markup — 100 buttons; практический лимит UI — 8).
      def build_keyboard(tasks)
        rows = tasks.first(8).map do |t|
          [
            { text: "▶ В работе ##{t.id}", callback_data: "task:#{t.id}:start" },
            { text: "✅ Выполнено ##{t.id}", callback_data: "task:#{t.id}:done" }
          ]
        end
        { inline_keyboard: rows }
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
