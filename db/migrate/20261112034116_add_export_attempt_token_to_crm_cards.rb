# frozen_string_literal: true

# Токен попытки выгрузки: захват approved → exporting в Workflow#export!
# атомарно ставит новый токен, и только попытка с совпадающим токеном имеет
# право писать crm_id и финализировать выгрузку. Без него живая первая
# попытка при recovery перезаписала бы crm_id карточки своим результатом.
# Защита от двух importClient — не токен, а гарды Workflow#retry_export!:
# из неоднозначного исхода новый importClient не вызывается вовсе,
# восстановление — attach_export_number! (ревью PR #210, round 7).
class AddExportAttemptTokenToCrmCards < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_cards, :export_attempt_token, :string
  end
end
