# frozen_string_literal: true

module Telegram
  module WorkBot
    # Polling-fallback для случаев когда TG → webhook не доходит из-за
    # network issue (host firewall / AS-фильтр у hosting provider).
    #
    # Запускается каждую минуту из sidekiq-cron (config/sidekiq_cron.yml,
    # job `tg_polling`). Long-polls 25s через `Telegram::Client#get_updates`.
    # Если updates есть — обрабатывает через тот же `Telegram::InboundProcessor`
    # что и webhook (общая точка входа: callback_query, message, message_reaction).
    # Offset (last_update_id) хранится в Rails.cache между запусками.
    #
    # Активация через ENV `TELEGRAM_POLLING_MODE=true`. Если переменная не
    # выставлена — job сразу exit'ит. Это позволяет быстро откатить на webhook
    # без удаления cron-записи.
    #
    # Mutual exclusion с webhook: getUpdates возвращает 409 conflict если
    # webhook установлен. Перед активацией polling — `bin/rails telegram:webhook:delete`.
    #
    # Не ActiveJob а plain Sidekiq Worker (`include Sidekiq::Job`) потому что
    # sidekiq-cron 1.12 не поддерживает ConfiguredJob.perform_async (см.
    # https://github.com/sidekiq-cron/sidekiq-cron/issues/...).
    class PollingJob
      include Sidekiq::Job

      sidekiq_options queue: :scheduled, retry: 2

      LOCK_KEY          = 'telegram:polling:lock'
      OFFSET_KEY        = 'telegram:polling:offset'
      LOCK_TTL          = 90.seconds
      LONG_POLL_TIMEOUT = 25
      BATCH_LIMIT       = 100

      def perform
        return :feature_disabled if ENV['TELEGRAM_POLLING_MODE'] != 'true'

        unless acquire_lock
          Rails.logger.info('[PollingJob] another instance running, skip')
          return :locked
        end

        client = Telegram::Client.new
        offset = (Rails.cache.read(OFFSET_KEY) || 0).to_i

        updates = client.get_updates(offset: offset + 1, limit: BATCH_LIMIT, timeout: LONG_POLL_TIMEOUT)
        return :no_updates if updates.blank?

        max_id = process_batch(updates)
        Rails.cache.write(OFFSET_KEY, max_id) if max_id.positive?

        Rails.logger.info("[PollingJob] processed=#{updates.size} max_id=#{max_id}")
        { processed: updates.size, max_id: max_id }
      ensure
        release_lock
      end

      private

      def acquire_lock
        Rails.cache.write(LOCK_KEY, Time.current.iso8601, expires_in: LOCK_TTL, unless_exist: true)
      end

      def release_lock
        Rails.cache.delete(LOCK_KEY)
      end

      def process_batch(updates)
        max_id = 0
        updates.each do |update|
          begin
            Telegram::InboundProcessor.new(update).call
          rescue StandardError => e
            Rails.logger.warn("[PollingJob] failed update_id=#{update['update_id']}: #{e.class}: #{e.message}")
          end
          uid = update['update_id'].to_i
          max_id = uid if uid > max_id
        end
        max_id
      end
    end
  end
end
