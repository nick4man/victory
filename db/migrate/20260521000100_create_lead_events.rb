# frozen_string_literal: true

# Состояние конвейера обработки лида.
# Связывает объект CRM (BuyerOrder/Property) с якорным сообщением бота
# в специализированном топике + опциональным тизером в СДЕЛКА.
# Карточка лида перемещается между топиками (ДИСПЕТЧЕРСКАЯ → специализация →
# опц. СДЕЛКА) — anchor_thread_id/anchor_message_id обновляются при каждом /route.
class CreateLeadEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :lead_events do |t|
      t.references :lead_ref, polymorphic: true, null: false, index: true

      t.string  :source,                 null: false        # 'site_form' | 'site_valuation' | 'site_mortgage' | 'tg_dm' | 'manual' | 'crm_webhook'
      t.bigint  :tg_chat_id,             null: false        # = chat_id из telegram_topics.yml
      t.integer :anchor_thread_id                            # message_thread_id текущего топика-якоря
      t.bigint  :anchor_message_id                           # message_id карточки в якорном топике
      t.string  :anchor_topic_key,       null: false, default: 'dispatcher'  # см. enum в LeadEvent
      t.bigint  :deal_mirror_message_id                      # message_id тизера в СДЕЛКА (если /stage договор|сделка)
      t.bigint  :dispatcher_message_id                       # message_id первоначальной карточки в ДИСПЕТЧЕРСКОЙ (для аудита)

      t.string  :current_stage,          null: false, default: 'new'  # new | first_contact | show | contract | deal | closed_won | closed_lost
      t.references :assigned_to, foreign_key: { to_table: :telegram_users }

      t.datetime :assigned_at
      t.datetime :first_contact_at
      t.datetime :closed_at

      t.jsonb   :metadata,               null: false, default: {}     # phone, name, summary, original payload

      t.timestamps
    end

    add_index :lead_events, :source
    add_index :lead_events, :current_stage
    add_index :lead_events, :anchor_topic_key
    add_index :lead_events, %i[anchor_thread_id anchor_message_id], name: 'idx_lead_events_anchor'
  end
end
