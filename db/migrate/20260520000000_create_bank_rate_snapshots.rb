# frozen_string_literal: true

# Historical snapshots of bank product rates scraped from banki.ru.
# Each row is one weekly run of the scraper for a given product kind
# (deposit / mortgage). Lets `Deposit::ProgramsService` serve always-fresh
# data without losing the safety-net of the hardcoded fallback constant,
# and gives admins a diff view to spot which programs changed since last
# week.
class CreateBankRateSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :bank_rate_snapshots do |t|
      t.date     :as_of,            null: false
      t.string   :kind,             null: false  # 'deposit' | 'mortgage'
      t.jsonb    :payload,          null: false  # array of {bank_name, product_name, rate_max, term_months_min, term_months_max, min_amount, source_url, ...}
      t.string   :source                          # 'banki.ru'
      t.integer  :items_count,      default: 0
      t.string   :status,           default: 'ok'  # 'ok' | 'partial' | 'failed'
      t.text     :error_log

      t.timestamps
    end

    add_index :bank_rate_snapshots, %i[kind as_of]
    add_index :bank_rate_snapshots, :status
  end
end
