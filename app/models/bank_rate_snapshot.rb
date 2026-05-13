# frozen_string_literal: true

# One weekly snapshot of bank product rates from banki.ru. Written by
# `BankRatesRefreshJob`, read by `Deposit::ProgramsService.from_snapshot`
# and the admin /admin/bank_rates page.
class BankRateSnapshot < ApplicationRecord
  KINDS    = %w[deposit mortgage].freeze
  STATUSES = %w[ok partial failed].freeze

  validates :as_of,   presence: true
  validates :kind,    inclusion: { in: KINDS }
  validates :status,  inclusion: { in: STATUSES }
  validates :payload, presence: true

  scope :recent,    -> { order(as_of: :desc, created_at: :desc) }
  scope :for_kind,  ->(k) { where(kind: k) }
  scope :ok,        -> { where(status: 'ok') }

  def self.latest_ok(kind)
    for_kind(kind).ok.recent.first
  end

  def items
    Array(payload)
  end

  # Diff vs the previous successful snapshot of the same kind. Returns a
  # hash of changes keyed by "<bank_name>|<product_name>".
  def diff_vs_previous
    prev = BankRateSnapshot.for_kind(kind).ok
                           .where('as_of < ?', as_of)
                           .recent.first
    return { added: items, removed: [], changed: [] } unless prev

    key = ->(i) { "#{i['bank_name']}|#{i['product_name']}" }
    by_key_now  = items.index_by(&key)
    by_key_prev = prev.items.index_by(&key)

    added = (by_key_now.keys - by_key_prev.keys).map { |k| by_key_now[k] }
    removed = (by_key_prev.keys - by_key_now.keys).map { |k| by_key_prev[k] }
    changed = by_key_now.filter_map do |k, item|
      old = by_key_prev[k]
      next nil unless old
      next nil if old['rate_max'].to_f == item['rate_max'].to_f
      { key: k, before: old, after: item }
    end

    { added: added, removed: removed, changed: changed }
  end
end
