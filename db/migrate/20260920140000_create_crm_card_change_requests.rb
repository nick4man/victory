# frozen_string_literal: true

# Заявка на правку опубликованной карточки. После того как карточка попала в
# CRM, поля в ней — уже запись в боевой базе: менять их молча нельзя. Ход
# работы (заметки) дописывается свободно, а правка поля проходит модерацию.
class CreateCrmCardChangeRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_card_change_requests do |t|
      t.references :crm_card, null: false, foreign_key: true
      t.references :author, null: false, foreign_key: { to_table: :telegram_users }
      t.references :reviewer, null: true, foreign_key: { to_table: :telegram_users }
      t.string :field, null: false
      t.jsonb :old_value
      t.jsonb :new_value
      t.string :status, null: false, default: 'pending'
      t.text :comment
      t.datetime :reviewed_at
      t.timestamps
    end

    # Одно поле — одна открытая заявка: две параллельные правки одного номера
    # телефона модератор развести не сможет.
    add_index :crm_card_change_requests, %i[crm_card_id field],
              unique: true, where: "status = 'pending'",
              name: 'index_crm_card_change_requests_pending_field'
  end
end
