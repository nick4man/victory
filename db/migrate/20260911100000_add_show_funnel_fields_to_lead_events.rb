# frozen_string_literal: true

# BOTTLENECK — базовая линия эксперимента «агент показывает, руководитель торгуется».
#
# segment       — квалификация покупателя, которую агент и так выясняет по Шагу 4,
#                 но которую негде было сохранить; без неё сравнение конверсий
#                 между агентом и руководителем — selection bias в чистом виде.
# property_id   — денормализация lead_ref → Property: метрики считаются по объектам,
#                 а полиморфный join по трём формам ref'а не индексируется.
# first_show_at — момент первого показа (ставится при переходе в стадию show
#                 и/или подтверждении ShowReport), ключ когорты.
# contract_at   — момент перехода в contract; конверсия показ→договор считается
#                 по этим двум датам, а не по чтению stage_history из jsonb.
class AddShowFunnelFieldsToLeadEvents < ActiveRecord::Migration[8.1]
  def up
    change_table :lead_events, bulk: true do |t|
      t.string     :segment, limit: 32 # cash | mortgage_approved | mortgage_pending | alternative | cold
      t.references :property, foreign_key: true, null: true, index: true
      t.datetime   :first_show_at
      t.datetime   :contract_at
    end
    add_index :lead_events, :segment
    add_index :lead_events, :first_show_at
    add_index :lead_events, %i[property_id current_stage]

    # Бэкфилл property_id из двух форм ref'а, которые знают объект.
    # PropertyValuation и BuyerOrder объекта не имеют — остаются NULL.
    execute <<~SQL.squish
      UPDATE lead_events SET property_id = lead_ref_id
      WHERE lead_ref_type = 'Property' AND property_id IS NULL
        AND EXISTS (SELECT 1 FROM properties p WHERE p.id = lead_events.lead_ref_id)
    SQL
    execute <<~SQL.squish
      UPDATE lead_events le SET property_id = i.property_id
      FROM inquiries i
      WHERE le.lead_ref_type = 'Inquiry' AND le.lead_ref_id = i.id
        AND le.property_id IS NULL AND i.property_id IS NOT NULL
        AND EXISTS (SELECT 1 FROM properties p WHERE p.id = i.property_id)
    SQL
    # Бэкфилл дат из stage_history: первое появление 'to'=>'show' / 'contract'.
    execute <<~SQL.squish
      UPDATE lead_events le SET first_show_at = sub.at
      FROM (
        SELECT id, MIN((e->>'at')::timestamp) AS at
        FROM lead_events, jsonb_array_elements(COALESCE(metadata->'stage_history', '[]'::jsonb)) e
        WHERE e->>'to' = 'show' GROUP BY id
      ) sub
      WHERE le.id = sub.id AND le.first_show_at IS NULL
    SQL
    execute <<~SQL.squish
      UPDATE lead_events le SET contract_at = sub.at
      FROM (
        SELECT id, MIN((e->>'at')::timestamp) AS at
        FROM lead_events, jsonb_array_elements(COALESCE(metadata->'stage_history', '[]'::jsonb)) e
        WHERE e->>'to' = 'contract' GROUP BY id
      ) sub
      WHERE le.id = sub.id AND le.contract_at IS NULL
    SQL
  end

  def down
    remove_index :lead_events, %i[property_id current_stage]
    remove_index :lead_events, :first_show_at
    remove_index :lead_events, :segment
    remove_reference :lead_events, :property, foreign_key: true
    remove_column :lead_events, :contract_at
    remove_column :lead_events, :first_show_at
    remove_column :lead_events, :segment
  end
end
