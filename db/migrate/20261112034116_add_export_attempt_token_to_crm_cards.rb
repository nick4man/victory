# frozen_string_literal: true

# Токен попытки выгрузки: захват approved → exporting в Workflow#export!
# атомарно ставит новый токен, и только попытка с совпадающим токеном имеет
# право финализировать выгрузку. Иначе ручной «Повторить» по stale-карточке,
# чья первая выгрузка ещё жива, приводил к двум importClient и перезаписи
# crm_id чужой попыткой (ревью PR #210).
class AddExportAttemptTokenToCrmCards < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_cards, :export_attempt_token, :string
  end
end
