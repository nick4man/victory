# frozen_string_literal: true

# #413f Шаг 5 — analytics для измерения работы awareness mechanisms.
#
# Каждое успешное cabinet-activation (TG linked + invited_at set) пишет
# одну строку в activation_events. Channels:
#   - 'inbound'         — клиент сам пришёл в @anvictorybot (no token,
#                          contact-share flow в ActivationRequestProcessor)
#   - 'cabinet_profile' — opt-in flow из /cabinet/profile UI (user уже
#                          logged in via email/magic-link, добавил TG)
#   - 'admin_panel'     — агент в /admin/users/:id сгенерил → share
#                          (WhatsApp / email / в офисе)
#   - 'bulk_pdf'        — rake tg:activation:bulk_generate → печатные QR
#
# Use-case: weekly digest «сколько активаций по каналам» → понять какие
# awareness mechanisms работают. Например 80% bulk_pdf и 5% inbound →
# нужно усилить awareness; 70% inbound и 5% admin_panel → агенты
# недогруже­ны.
class CreateActivationEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :activation_events do |t|
      t.references :user, null: false, foreign_key: true
      t.string :channel, null: false, limit: 32
      t.datetime :happened_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.string :ip_address, limit: 45
      t.timestamps
    end

    add_index :activation_events, :channel
    add_index :activation_events, :happened_at
  end
end
