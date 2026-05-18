# frozen_string_literal: true

# Phase 4D/4H — Client attribution columns на Inquiry. Закрывает Phase 4H
# multi-channel dedup (phone > tg_user_id > email match priority) + Phase 4D
# TG-DM intake storage (нужен tg_user_id для returning client detection).
class AddClientAttributionToInquiries < ActiveRecord::Migration[7.1]
  def change
    add_column :inquiries, :client_tg_user_id, :bigint
    add_column :inquiries, :client_phone_e164, :string  # normalized E.164 без +
    add_column :inquiries, :client_email_norm, :string  # lowercased, stripped
    add_column :inquiries, :attribution_source, :string # 'site_form', 'tg_dm',
                                                        # 'manual', 'crm_webhook',
                                                        # 'site_valuation', 'site_mortgage'

    # Match-priority indices (Phase 4H dedup):
    #   phone (E.164) > tg_user_id > email
    add_index :inquiries, :client_phone_e164, where: 'client_phone_e164 IS NOT NULL'
    add_index :inquiries, :client_tg_user_id, where: 'client_tg_user_id IS NOT NULL'
    add_index :inquiries, :client_email_norm, where: 'client_email_norm IS NOT NULL'

    # Frequent query: «recent inquiries from same tg_user_id за 90d»
    add_index :inquiries, [:client_tg_user_id, :created_at],
              where: 'client_tg_user_id IS NOT NULL',
              name: 'idx_inquiries_tg_recent'
  end
end
