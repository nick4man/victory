# frozen_string_literal: true

# Карточка для CRM проходит ручную модерацию, прежде чем попасть в Topnlab.
# Заявка с формы сайта бывает спамом, а удалять в CRM мы сознательно не
# умеем — мусор остался бы там навсегда (см. docs/superpowers/specs/
# 2026-09-14-crm-card-moderation-design.md).
#
# Уникальность «одна карточка заявки на лид» — индексом, а не валидацией:
# две кнопки, нажатые в одну секунду, валидация пропустила бы обе.
# Объекты без лида (заведены из меню) под индекс не попадают.
#
# Журнал переходов — отдельной таблицей: без него на вопрос «почему вернули
# на доработку» ответа нет, а комментарий модератора — главное в возврате.
class CreateCrmCards < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_cards do |t|
      t.string     :kind,         null: false                      # lead | object
      t.string     :status,       null: false, default: 'draft'
      t.references :lead_event,   foreign_key: true
      t.references :author,       null: false, foreign_key: { to_table: :telegram_users }
      t.references :reviewer,     foreign_key: { to_table: :telegram_users }
      t.jsonb      :payload,      null: false, default: {}
      t.jsonb      :check_errors, null: false, default: []
      t.datetime   :checked_at
      t.datetime   :submitted_at
      t.datetime   :reviewed_at
      t.string     :export_mode                                    # api | manual
      t.string     :crm_id
      t.datetime   :exported_at
      t.text       :export_error
      t.datetime   :deleted_at
      t.timestamps
    end
    add_index :crm_cards, %i[status submitted_at]
    add_index :crm_cards, :deleted_at
    add_index :crm_cards, %i[lead_event_id kind], unique: true,
                                                   where: 'deleted_at IS NULL AND lead_event_id IS NOT NULL',
                                                   name: 'idx_crm_cards_one_per_lead'

    create_table :crm_card_transitions do |t|
      t.references :crm_card, null: false, foreign_key: true
      t.string     :from_status, null: false
      t.string     :to_status,   null: false
      t.references :actor, foreign_key: { to_table: :telegram_users }
      t.text       :comment
      t.datetime   :created_at, null: false
    end
  end
end
