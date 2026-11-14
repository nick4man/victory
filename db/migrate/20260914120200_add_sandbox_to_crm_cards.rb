# frozen_string_literal: true

# Песочница тестового бота работает на боевой базе. Флаг отделяет её
# карточки от рабочих: их не видно в рабочем боте и наоборот, а выгрузка
# песочницы не пишет в Topnlab.
class AddSandboxToCrmCards < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_cards, :sandbox, :boolean, null: false, default: false
    add_index :crm_cards, %i[sandbox status]
  end
end
