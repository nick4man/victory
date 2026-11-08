# frozen_string_literal: true

# Нормализация legacy land_area к соткам. YrlParser до PR #184 сохранял
# <lot-area> без учёта unit: фиды в кв. м (например 800) попадали в
# land_area как есть, и ComparableFinder читал их как 800 соток — ₽/м²
# занижался в 100 раз, а band-фильтр отбрасывал запись для обычных
# участков (ревью Kimi r7, PR #184). После фикса парсера новые записи
# всегда в сотках; здесь — бэкфилл старых.
#
# Порог 500 соток (5 га): для рынка Рязани это заведомо кв. м, а не
# реальный участок. Записи с меньшим land_area не трогаем — неотличимо,
# в какой единице они были распарсены.
class NormalizeYrlLandAreaToSotki < ActiveRecord::Migration[8.1]
  LEGACY_SOTKI_CAP = 500

  def up
    execute <<~SQL.squish
      UPDATE external_listings
      SET land_area = land_area / 100
      WHERE property_type = 'land'
        AND land_area > #{LEGACY_SOTKI_CAP}
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
