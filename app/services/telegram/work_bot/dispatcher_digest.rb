# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 7.4 — Pinned daily digest задач в #ДИСПЕТЧЕРСКАЯ.
    #
    # Один сообщение в день обновляется через editMessageText в течение дня.
    # На следующий день — новый сообщение, старое unpin'нуто через
    # DigestCleanupJob (cron 00:05).
    #
    # Содержит todays-tasks сгруппированные по assignee, с emoji по статусу
    # (⏳ open / ✅ done / ⚠️ overdue) и подсчётом snapshot.
    #
    # @example
    #   Telegram::WorkBot::DispatcherDigest.refresh_for_today!
    #   # → постит новый pinned или редактирует существующий
    #
    # Trigger points:
    #   • TaskBatchConfirmCallback#approve — после создания tasks
    #   • Task#after_commit — на любое status/completed_at update
    #   • Cron — в случае drift (Phase 7.4+ optional)
    class DispatcherDigest
      class Error < StandardError; end

      DISPATCHER_CHAT_ID    = -1_003_779_115_845 # «🚀 Виктори | Конвейер сделок»
      # Phase 7.4 MVP — постим в General (thread_id=nil = #ДИСПЕТЧЕРСКАЯ).
      DISPATCHER_THREAD_ID  = nil

      def self.refresh_for_today!(**)
        new(**).refresh!
      end

      def initialize(date: Date.current, chat_id: DISPATCHER_CHAT_ID,
                     thread_id: DISPATCHER_THREAD_ID, client: Telegram::Client.new)
        @date      = date
        @chat_id   = chat_id
        @thread_id = thread_id
        @client    = client
      end

      def refresh!
        tasks = tasks_for_date
        text  = build_text(tasks)
        digest = DailyDigest.for_date(@date).first

        if digest && digest.tg_chat_id == @chat_id && !digest.archived?
          edit_existing!(digest, text, tasks)
        else
          post_new!(text, tasks)
        end
      rescue StandardError => e
        Rails.logger.error("[DispatcherDigest] #{e.class}: #{e.message}")
        nil
      end

      private

      def tasks_for_date
        day_range = @date.all_day
        ::Task.where('assigned_at IS NOT NULL AND ' \
                     '(assigned_at BETWEEN :start AND :end OR completed_at BETWEEN :start AND :end)',
                     start: day_range.begin, end: day_range.end)
              .where.not(status: 'canceled')
              .order(:priority, :assigned_at)
              .to_a
      end

      def build_text(tasks)
        date_str = @date.strftime('%d.%m.%y')
        lines = ["📋 <b>Дайджест задач — #{date_str}</b>"]
        lines << '<i>Обновляется автоматически по ходу дня</i>'
        lines << ''

        if tasks.empty?
          lines << '<i>Сегодня без задач.</i>'
        else
          stats = task_stats(tasks)
          lines << format_stats(stats)
          lines << ''

          group_by_assignee(tasks).each do |assignee, group|
            lines << assignee_header(assignee, group)
            group.each { |t| lines << format_task_line(t) }
            lines << ''
          end
        end

        lines << "<i>Обновлено в #{Time.current.strftime('%H:%M')}</i>"
        lines.join("\n")
      end

      def group_by_assignee(tasks)
        tasks.group_by(&:assignee).sort_by { |a, _| a&.display_name.to_s }
      end

      def assignee_header(assignee, group)
        mention = assignee&.mention.presence || '(не назначен)'
        done = group.count(&:status_done?)
        "👤 <b>#{escape(mention)}</b> — #{done}/#{group.size} ✅"
      end

      def format_task_line(task)
        icon = task_icon(task)
        title = task.title.to_s[0, 80]
        line = "  #{icon} #{escape(title)}"
        line = "  #{icon} <s>#{escape(title)}</s>" if task.status_done?
        line += " <i>(#{format_due(task.due_at)})</i>" if task.due_at
        line += ' ⚠️' if task.suspicious_flag?
        line
      end

      def task_icon(task)
        return '✅' if task.status_done?
        return '⚠️ ' if overdue?(task)

        '⏳'
      end

      def overdue?(task)
        task.due_at.present? && task.due_at < Time.current && task.status_open?
      end

      def format_due(due_at)
        due_at < Time.current ? "просрочена #{due_at.strftime('%H:%M')}" : "до #{due_at.strftime('%H:%M')}"
      end

      def task_stats(tasks)
        {
          total: tasks.size,
          done: tasks.count(&:status_done?),
          open: tasks.count(&:status_open?),
          overdue: tasks.count { |t| overdue?(t) },
          urgent: tasks.count(&:priority_urgent?),
          suspicious: tasks.count(&:suspicious_flag?)
        }
      end

      def format_stats(stats)
        parts = ["📊 <b>#{stats[:total]}</b> задач"]
        parts << "✅ <b>#{stats[:done]}</b>" if stats[:done].positive?
        parts << "⏳ <b>#{stats[:open]}</b>" if stats[:open].positive?
        parts << "⚠️ <b>#{stats[:overdue]}</b> overdue" if stats[:overdue].positive?
        parts << "🔴 <b>#{stats[:urgent]}</b> urgent" if stats[:urgent].positive?
        parts << "🤔 <b>#{stats[:suspicious]}</b> suspicious" if stats[:suspicious].positive?
        parts.join(' · ')
      end

      def post_new!(text, tasks)
        msg = @client.send_message(text, chat_id: @chat_id,
                                         message_thread_id: @thread_id,
                                         parse_mode: 'HTML')
        return nil unless msg&.dig('message_id')

        pin_safely(msg['message_id'])

        DailyDigest.create!(
          date: @date,
          tg_chat_id: @chat_id,
          tg_thread_id: @thread_id,
          tg_message_id: msg['message_id'],
          topic_key: 'dispatcher',
          posted_at: Time.current,
          tasks_count: tasks.size,
          done_count: tasks.count(&:status_done?)
        )
      end

      def edit_existing!(digest, text, tasks)
        @client.edit_message_text(text, chat_id: digest.tg_chat_id,
                                        message_id: digest.tg_message_id,
                                        parse_mode: 'HTML')
        digest.update!(tasks_count: tasks.size, done_count: tasks.count(&:status_done?))
        digest
      rescue Telegram::Client::Error => e
        # «message is not modified» — норма (digest без изменений), не warning.
        return digest if e.message.to_s.include?('not modified')

        Rails.logger.warn("[DispatcherDigest] edit failed: #{e.message}")
        digest
      end

      def pin_safely(message_id)
        @client.pin_chat_message(chat_id: @chat_id, message_id: message_id,
                                 disable_notification: true)
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[DispatcherDigest] pin failed: #{e.message}")
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
