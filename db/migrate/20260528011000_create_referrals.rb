# frozen_string_literal: true

# Phase 3 MLS/YRL — лид-передача партнёрскому агентству. Один Referral =
# один Inquiry на чужой объект который мы передаём (или planируем передать)
# партнёру за commission share.
#
# State machine (status enum):
#   pending      → ждёт ручного review админом
#   forwarded    → передали партнёру (forwarded_at установлен)
#   in_progress  → партнёр work'ает с лидом (показ запланирован, переговоры)
#   closed_won   → сделка закрыта, ожидаем расчёт (final_commission_amount)
#   closed_lost  → отказались / не сложилось
#   stale        → партнёр не отвечает > 30 days, manual review needed
#
# Auto-create logic: Referrals::AutoCreator вызывается после Inquiry create
# если inquiry.external_listing_id present. Заводит pending с
# commission_rate = partner_agency.default_commission_rate.
#
# Soft-delete для GDPR / audit-trail consistency.
class CreateReferrals < ActiveRecord::Migration[7.1]
  def change
    create_table :referrals do |t|
      t.references :inquiry,           null: false, foreign_key: true
      t.references :partner_agency,    null: false, foreign_key: true
      t.references :external_listing,  null: true,  foreign_key: true
      t.string     :status,            null: false, default: 'pending'
      t.decimal    :commission_rate,   precision: 5, scale: 4
      t.decimal    :final_commission_amount, precision: 12, scale: 2
      t.datetime   :forwarded_at
      t.datetime   :closed_at
      t.text       :agent_notes                                  # internal log
      t.jsonb      :metadata, default: {}
      t.datetime   :deleted_at
      t.timestamps
    end

    add_index :referrals, :status
    add_index :referrals, :deleted_at,    where: 'deleted_at IS NOT NULL'
    add_index :referrals, %i[partner_agency_id status]
  end
end
