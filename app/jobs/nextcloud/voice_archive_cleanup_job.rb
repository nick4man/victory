# frozen_string_literal: true

module Nextcloud
  # Phase 7.8b — Weekly cleanup voice-archive файлов > 90 дней.
  #
  # MVP-стратегия (НЕ удаляем файлы автоматически в NC — это сохраняет audit
  # trail на случай юридических запросов):
  #   1. Soft-delete DocumentUpload запись (deleted_at = now)
  #   2. Log файл для manual review/move
  #
  # Phase 7.8b+ TODO: автоматический move в `<Type>/АРХИВ/voice-tasks-<YEAR>/`
  # через WebDAV MOVE (нужно добавить в Nextcloud::Client).
  #
  # Cron: weekly Sunday 04:00 Moscow (после daily digest cleanup в 00:05).
  class VoiceArchiveCleanupJob
    include Sidekiq::Job

    sidekiq_options queue: :scheduled, retry: 1

    RETENTION_PERIOD = 90.days

    def perform
      cutoff = RETENTION_PERIOD.ago
      stale  = DocumentUpload.where(purpose: 'voice-archive')
                             .where(uploaded_at: ...cutoff)
                             .where(deleted_at: nil)
      count = stale.count
      return :no_stale if count.zero?

      paths = stale.pluck(:nextcloud_path)
      stale.update_all(deleted_at: Time.current)

      Rails.logger.info("[Nextcloud::VoiceArchiveCleanupJob] soft-deleted #{count} voice-archive records " \
                        "older than #{RETENTION_PERIOD.inspect}. NC paths preserved for manual archive:\n" \
                        "#{paths.join("\n")}")
      { soft_deleted: count, retention_days: RETENTION_PERIOD.to_i / 86_400 }
    end
  end
end
