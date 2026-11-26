# frozen_string_literal: true

# Повторяемость сбоя выгрузки. true (default) — автоматический повтор из
# export_failed разрешён: так вели себя все сбои до этой миграции. false —
# неоднозначный исход (ReadTimeout/обрыв после отправки, номер есть, а статус
# не записан): CRM могла принять заявку, повтор только после ручной сверки
# модератора с CRM (ревью PR #210). fail_export! выставляет флаг явно.
class AddExportRetryableToCrmCards < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_cards, :export_retryable, :boolean, default: true, null: false
  end
end
