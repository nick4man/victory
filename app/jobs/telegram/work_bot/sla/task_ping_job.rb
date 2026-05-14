# frozen_string_literal: true

module Telegram
  module WorkBot
    module Sla
      # Job-обёртка над отправкой DM «📌 Просрочена задача» с self-defer
      # на quiet hours (21:00-07:00 Moscow → defer до 07:00 next day).
      class TaskPingJob < ApplicationJob
        queue_as :scheduled

        def perform(task_id)
          defer = QuietHours.defer_until
          if defer
            Rails.logger.info("[Sla::TaskPingJob] quiet hours — defer to #{defer.iso8601} task=#{task_id}")
            self.class.set(wait_until: defer).perform_later(task_id)
            return :deferred
          end

          task = ::Task.find_by(id: task_id)
          return :missing unless task
          return :not_open unless task.status_open?
          return :no_assignee if task.assignee.blank?

          send_dm(task)
          task.update!(last_pinged_at: Time.current)
          :delivered
        end

        private

        def send_dm(task)
          chat_id = task.assignee.dm_chat_id || task.assignee.tg_user_id
          return if chat_id.blank?

          text = "📌 Просрочена задача: <b>#{escape(task.title)}</b>\n" \
                 "Срок был: #{Formatters::DateFormat.fmt(task.due_at)}\n" \
                 "#{anchor_link(task)}"

          Telegram::Client.new.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[Sla::TaskPingJob] DM failed task=#{task.id}: #{e.message}")
        end

        def anchor_link(task)
          return '' if task.lead_event.blank?

          task.lead_event.anchor_url.to_s
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
