# frozen_string_literal: true

module Kpi
  # Phase 7.6 — cron 18:00 daily Moscow. Шлёт DM Оксане (и admin-уровню если есть)
  # с agency-wide summary текущего дня.
  class AgencyDigestJob
    include Sidekiq::Job

    sidekiq_options queue: :scheduled, retry: 2

    def perform(date_str = nil)
      date = date_str.present? ? Date.parse(date_str) : Date.current

      # Phase 9 Iter 9 — НЕ вызываем StaffSnapshot.run! здесь.
      # Snapshot уже запускается в 23:55 prior day через Kpi::StaffSnapshotJob.
      # Раньше — double-compute (одни и те же metrics дважды). Если данные
      # старше суток нужны — отдельно вручную через console.

      text = Kpi::AgencyDigest.new(date: date).build_text
      send_to_directors(text)

      Rails.logger.info("[Kpi::AgencyDigestJob] sent agency digest for #{date}")
    end

    private

    def send_to_directors(text)
      client = Telegram::Client.new
      recipients = TelegramUser.directors.active + TelegramUser.where(role: 'admin').active
      recipients.uniq.each do |r|
        chat_id = r.dm_chat_id || r.tg_user_id
        next if chat_id.blank?

        client.send_message(text, chat_id: chat_id, parse_mode: 'HTML',
                                  disable_web_page_preview: true)
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[Kpi::AgencyDigestJob] DM to #{r.mention} failed: #{e.message}")
      end
    end
  end
end
