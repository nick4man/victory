# frozen_string_literal: true

# Разрешение на выгрузку — третья ступень конвейера. Одобряет карточку
# модератор, а решение отправить её в CRM принимает держатель права export
# (директор, позже — РОП). До этого решения одобренная карточка никуда не
# уходит: у заявки не запускается выгрузка, у объекта автор не видит кнопку
# «Внесено в CRM».
class AddReleaseToCrmCards < ActiveRecord::Migration[8.1]
  def change
    add_reference :crm_cards, :released_by, foreign_key: { to_table: :telegram_users }, null: true
    add_column :crm_cards, :released_at, :datetime, null: true
  end
end
