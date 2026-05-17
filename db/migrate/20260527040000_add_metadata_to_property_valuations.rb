# frozen_string_literal: true

# B2: foreign-audit нужно отдельное поле metadata для:
#   - audit_locale (en/ru)
#   - secondary_currency (USD)
#   - foreign_audit (bool flag)
#   - exchange_rates (snapshot)
#   - visa_chapter_en (LLM-generated content)
#
# Не используем существующий `evaluation_data` jsonb потому что:
#   1. Он наполняется audit-engine (Python) и затирается на каждый MC run
#   2. Mixing наших client-side meta + engine output ломает invariants
#   3. Otherwise чтобы сохранить visa_chapter_en через MC reruns нужен сложный merge
#
# Pattern mirrors Inquiry.metadata jsonb (тот же подход для chat-leads).
class AddMetadataToPropertyValuations < ActiveRecord::Migration[7.1]
  def change
    add_column :property_valuations, :metadata, :jsonb, default: {}, null: false
    add_index  :property_valuations, :metadata, using: :gin
  end
end
