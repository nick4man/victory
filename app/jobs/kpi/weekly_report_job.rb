# frozen_string_literal: true

module Kpi
  # Phase 6 — Cron Monday 10:00 MSK. Builds WeeklyReport за прошедшую
  # Mon-Sun неделю, sends DM всем managers + directors. Use CriticalRecipients
  # cascade pattern (Phase 11 Iter 25) для consistency — но non-critical
  # alert level (not throttled).
  class WeeklyReportJob < ApplicationJob
    queue_as :scheduled

    def perform
      text = Kpi::WeeklyReport.new.build_text

      tg_client = Telegram::Client.new
      sent = 0
      skipped = 0
      # Senior staff: managers + directors. Не используем CriticalRecipients
      # (не cascade — недельный отчёт actually нужен всем managers + directors,
      # не только primary tier).
      recipients = TelegramUser.where(status: 'active')
                               .where('is_manager = ? OR role IN (?)', true, %w[director admin])
                               .distinct

      recipients.find_each do |tu|
        chat_id = tu.dm_chat_id || tu.tg_user_id
        if chat_id.blank?
          skipped += 1
          next
        end

        tg_client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        sent += 1
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[Kpi::WeeklyReportJob] DM to #{tu.mention} failed: #{e.message}")
        skipped += 1
      end

      Rails.logger.info("[Kpi::WeeklyReportJob] sent=#{sent}, skipped=#{skipped}")
      { sent: sent, skipped: skipped }
    end
  end
end
