# frozen_string_literal: true

# Visibility decoupling (см. plan: «Decouple Site Visibility from
# Outbound Advertising»).
#
# `force_archive` — admin explicit hide. Симметричный к существующему
# `force_publish`. Используется когда:
#   - Жалоба клиента, нужно срочно снять с сайта
#   - Объект в спорной ситуации (документы, сделка под вопросом)
#   - Любой другой admin-side reason скрыть от посетителей
#
# Partial index — только TRUE values (force_archive=true это редкое
# исключение, FALSE значения не нужны в индексе).
class AddForceArchiveToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :force_archive, :boolean, null: false, default: false
    add_index  :properties, :force_archive, where: 'force_archive = TRUE'
  end
end
