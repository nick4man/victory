# frozen_string_literal: true

module Telegram
  module WorkBot
    # Возврат закрытой задачи в работу в окне 24 часа. Общий путь для
    # `/reopen <id>` и мастера «Переоткрытие задачи»; тексты ответов — у
    # вызывающего, здесь только решение и побочные эффекты.
    #
    #   • assignee своей задачи ИЛИ manager (override)
    #   • окно REOPEN_WINDOW от completed_at/updated_at — позже следы в digest/KPI
    #     уже зафиксированы, легче создать новую задачу
    #   • сброс completed_at/acked_method/suspicious_flag, first_acked_at остаётся
    #     (запись «работа была начата»)
    #   • DM assignee, когда manager переоткрывает чужую
    class TaskReopen
      REOPEN_WINDOW = 24.hours

      # status: :reopened | :forbidden | :already_open | :expired
      Result = Struct.new(:status, :prev_status, :closed_at, keyword_init: true)

      def initialize(task, actor:, client: Telegram::Client.new)
        @task = task
        @actor = actor
        @client = client
      end

      def call
        return Result.new(status: :forbidden) unless self.class.authorized?(@task, @actor)
        return Result.new(status: :already_open) if @task.status_open?

        closed_at = self.class.closed_at(@task)
        return Result.new(status: :expired, closed_at: closed_at) if self.class.expired?(@task)

        prev_status = @task.status
        ::Task.transaction do
          @task.assign_attributes(status: 'open', completed_at: nil, acked_method: nil, suspicious_flag: false)
          @task.save!
        end
        notify_assignee_if_third_party(prev_status)
        Result.new(status: :reopened, prev_status: prev_status, closed_at: closed_at)
      end

      def self.authorized?(task, actor)
        return false if actor.nil?

        task.assignee_id == actor.id || actor.is_manager?
      end

      def self.closed_at(task)
        task.completed_at || task.updated_at
      end

      def self.expired?(task)
        at = closed_at(task)
        at.present? && at < REOPEN_WINDOW.ago
      end

      private

      def notify_assignee_if_third_party(prev_status)
        assignee = @task.assignee
        return if assignee.nil? || assignee.id == @actor.id

        chat_id = assignee.dm_chat_id || assignee.tg_user_id
        return if chat_id.blank?

        due_str = @task.due_at ? "до #{@task.due_at.strftime('%d.%m.%y %H:%M')}" : 'без срока'
        text = "↩️ <b>Твоя задача снова в работе</b> ##{@task.id}\n" \
               "📋 #{escape_html(@task.title)}\n" \
               "⏰ #{due_str}\n" \
               "Была: <b>#{prev_status}</b> · переоткрыл: #{@actor.mention}"
        @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[TaskReopen] DM failed for #{assignee&.mention}: #{e.message}")
      end

      def escape_html(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
