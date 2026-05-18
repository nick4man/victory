# frozen_string_literal: true

module Kpi
  # Phase 6 — Daily 08:00 MSK cron. Iterates TelegramUser.assignable, builds
  # personalized MorningDigest, sends DM each. Skip если no dm_chat_id
  # (user никогда не писал боту /start — TG не позволит инициировать).
  #
  # Quiet hours: НЕ применяются (08:00 это и есть желаемое утро).
  # Weekend: skipped — agency не работает Sat/Sun (Phase 4F same convention).
  class MorningDigestJob < ApplicationJob
    queue_as :scheduled

    def perform
      if weekend?
        Rails.logger.info('[Kpi::MorningDigestJob] weekend skip')
        return :weekend_skip
      end

      tg_client = Telegram::Client.new
      stats = { sent: 0, skipped: 0, errors: 0 }

      TelegramUser.assignable.find_each do |staff|
        chat_id = staff.dm_chat_id || staff.tg_user_id
        if chat_id.blank?
          Rails.logger.info("[Kpi::MorningDigestJob] skip #{staff.mention} — no dm_chat_id")
          stats[:skipped] += 1
          next
        end

        text = Kpi::MorningDigest.new(staff: staff).build_text
        tg_client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        stats[:sent] += 1
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[Kpi::MorningDigestJob] DM to #{staff.mention} failed: #{e.message}")
        stats[:errors] += 1
      rescue StandardError => e
        Rails.logger.error("[Kpi::MorningDigestJob] #{staff.mention}: #{e.class}: #{e.message}")
        stats[:errors] += 1
      end

      Rails.logger.info("[Kpi::MorningDigestJob] done: #{stats.inspect}")
      stats
    end

    private

    def weekend?
      Time.current.saturday? || Time.current.sunday?
    end
  end
end
