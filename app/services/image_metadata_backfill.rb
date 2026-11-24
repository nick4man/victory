# frozen_string_literal: true

# Бэкфилл width/height у ActiveStorage-блобов картинок, у которых анализ
# прошёл, но размеры не записались (issue #53). Исторический зазор мая–сент. 26:
# образ контейнера без рабочего vips тихо возвращал пустой metadata, а блоб
# всё равно помечался analyzed — analyze_later больше не срабатывает, состояние
# постоянное. Текущий образ исправен (проверено живым прогоном на проде).
#
# Идемпотентно: выборка каждый раз — «картинки без width в metadata», прерванный
# прогон продолжается повторным запуском. Ошибки отдельных блобов (битый файл,
# исчезнувший объект хранилища) не роняют прогон — считаются и логируются;
# блобы, у которых после анализа размеры всё равно не появились (например svg),
# отделяются в счётчик no_dims, чтобы не смешивать с реальными провалами.
class ImageMetadataBackfill
  def self.call(**args)
    new(**args).call
  end

  def initialize(batch_size: 100, sleep_seconds: 0.2, limit: nil, dry_run: false, logger: Rails.logger)
    @batch_size    = batch_size.to_i
    @sleep_seconds = sleep_seconds.to_f
    @limit         = limit&.to_i
    @dry_run       = dry_run
    @logger        = logger
  end

  def call
    total = scope.count
    logger.info("[image_backfill] start total=#{total} batch=#{batch_size} sleep=#{sleep_seconds}s dry_run=#{dry_run}")
    done = failed = no_dims = 0

    scope.find_each(batch_size: batch_size) do |blob|
      if dry_run
        done += 1
      else
        outcome = analyze_one(blob)
        case outcome
        when :ok then done += 1
        when :failed then failed += 1
        when :no_dims then no_dims += 1
        end
      end
      sleep(sleep_seconds) if sleep_seconds.positive?
      processed = done + failed + no_dims
      logger.info("[image_backfill] progress processed=#{processed}/#{total}") if (processed % 100).zero?
    end

    logger.info("[image_backfill] finish done=#{done} failed=#{failed} no_dims=#{no_dims} total=#{total}")
    { done: done, failed: failed, no_dims: no_dims, total: total }
  end

  private

  attr_reader :batch_size, :sleep_seconds, :limit, :dry_run, :logger

  # metadata — text-колонка: LIKE-достаточно. Повторный запуск подхватывает
  # только остаток без width.
  def scope
    @scope ||= begin
      s = ActiveStorage::Blob.where('content_type LIKE ?', 'image/%')
                             .where("metadata NOT LIKE '%\"width\"%'")
      limit ? s.limit(limit) : s
    end
  end

  def analyze_one(blob)
    blob.analyze
    return :no_dims if blob.reload.metadata.to_s.exclude?('"width"')

    :ok
  rescue StandardError => e
    logger.warn(
      "[image_backfill] blob_id=#{blob.id} key=#{blob.key.to_s[0, 24]} " \
      "failed: #{e.class}: #{e.message.to_s.truncate(200)}"
    )
    :failed
  end
end
