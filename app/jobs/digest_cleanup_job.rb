# frozen_string_literal: true

# Phase 7.4 — Daily cron (00:05) для архивации вчерашних pinned digests.
#
#   1. Найти DailyDigest.stale (date < today, не archived)
#   2. unpin_chat_message в TG (best-effort — swallow errors)
#   3. mark archived_at
#   4. Seed today's digest если не существует (DispatcherDigest.refresh_for_today!)
#
# Cron 00:05 — после смены даты (UTC vs Moscow), seed свежего digest до того
# как агенты проснутся.
class DigestCleanupJob
  include Sidekiq::Job

  sidekiq_options queue: :scheduled, retry: 2

  def perform
    archive_stale!
    seed_today!
  end

  private

  def archive_stale!
    client = Telegram::Client.new
    DailyDigest.stale(before: Date.current).find_each do |digest|
      client.unpin_chat_message(chat_id: digest.tg_chat_id, message_id: digest.tg_message_id)
      digest.archive!
      Rails.logger.info("[DigestCleanupJob] archived digest ##{digest.id} (date=#{digest.date})")
    end
  end

  def seed_today!
    return if DailyDigest.for_date(Date.current).exists?

    Telegram::WorkBot::DispatcherDigest.refresh_for_today!
    Rails.logger.info("[DigestCleanupJob] seeded today's digest")
  end
end
