# frozen_string_literal: true

# BOTTLENECK — один показ = одна запись. До этого «показ проведён» существовало
# как стадия лида (без даты, без исхода) и как голосовое в чате (без данных).
# Возражения впервые становятся данными: «семь показов, пять раз кухня» —
# это и есть предметный разговор о цене с собственником (Шаг 4, этап 4).
#
# conducted_by ≠ reported_by: в базовой линии показывает руководитель, а
# диктует агент; после включения фильтра — наоборот. Именно пара
# (segment, conducted_by.role) и есть ось эксперимента.
#
# Не ViewingSchedule: та модель расходится со схемой (preferred_date которой нет
# в таблице) и нерабочая; строить на ней — унаследовать поломку.
class CreateShowReports < ActiveRecord::Migration[8.1]
  def change
    create_table :show_reports do |t|
      t.references :lead_event,   null: false, foreign_key: true
      t.references :property,     foreign_key: true
      t.references :conducted_by, null: false, foreign_key: { to_table: :telegram_users }
      t.references :reported_by,  null: false, foreign_key: { to_table: :telegram_users }
      t.datetime :conducted_at,   null: false
      t.string   :outcome,        null: false, default: 'thinking' # thinking | declined | second_show | bargain | deposit_intent
      t.jsonb    :objections,     null: false, default: []         # ['маленькая кухня', 'первый этаж']
      t.decimal  :offered_price,  precision: 15, scale: 2          # цена, названная покупателем (торг)
      t.string   :next_step                                        # «перезвонят в пятницу»
      t.text     :transcript_redacted                              # PII-маскированный транскрипт
      t.text     :owner_message                                    # черновик сообщения собственнику
      t.datetime :owner_notified_at
      t.string   :owner_notified_via                               # tg | manual
      t.bigint   :feedback_task_id                                 # Task «обратная связь до 11:00», FK логический
      t.string   :source,         null: false                      # voice | text
      t.string   :status,         null: false, default: 'pending_confirm' # pending_confirm | confirmed | cancelled | expired
      t.bigint   :preview_message_id
      t.bigint   :preview_chat_id
      t.jsonb    :uncertainties,  null: false, default: []
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :show_reports, %i[property_id conducted_at]
    add_index :show_reports, %i[status conducted_at]
    add_index :show_reports, :deleted_at
    add_index :show_reports, :reported_by_id, where: "status = 'pending_confirm'", name: 'idx_show_reports_pending_by_reporter'
  end
end
