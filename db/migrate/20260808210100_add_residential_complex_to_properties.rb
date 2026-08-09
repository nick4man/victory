# frozen_string_literal: true

# A2 — привязка объекта к ЖК (08.08.26).
#
# nullable + on_delete: :nullify — ЖК удаляется мягко, но даже жёсткое
# удаление не должно уносить объекты каталога.
#
# Привязка НЕ приходит из CRM и заполняется вручную. Она переживает
# Topnlab-синк: `Topnlab::Importer` делает upsert по (external_source,
# external_id) + assign_attributes из whitelist-хеша маппера, без
# destroy — `residential_complex_id` в этом хеше отсутствует, поэтому не
# перетирается. Проверить живьём после деплоя (см. план, Фаза 1).
#
# Индекс обычный, не CONCURRENTLY: в `properties` порядка сотни строк,
# блокировка на построение индекса измеряется миллисекундами, а
# disable_ddl_transaction! стоил бы атомарности миграции.
class AddResidentialComplexToProperties < ActiveRecord::Migration[7.1]
  def change
    add_reference :properties, :residential_complex,
                  null: true, foreign_key: { on_delete: :nullify }
  end
end
