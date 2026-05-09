# frozen_string_literal: true

# Lightweight cache of comparable real-estate listings sourced from external feeds
# (Topnlab MLS / parser network). Used by PropertyEvaluationService to compute
# median price per m² for valuations. Has no images, no friendly_id, no soft delete —
# rows refresh in place via MlsSync::TopnlabSyncService.
class MlsListing < ApplicationRecord
  reverse_geocoded_by :latitude, :longitude

  scope :priced,     -> { where('price > 0 AND price_per_sqm > 0') }
  scope :recent,     ->(days = 60) { where('synced_at > ?', days.days.ago) }
  scope :for_deal,   ->(t) { where(deal_type: t) }
  scope :realty,     ->(t) { where(realty_type: t) }
  scope :area_band,  ->(a, pct = 0.15) {
    next all if a.to_f <= 0
    where(area: (a.to_f * (1 - pct))..(a.to_f * (1 + pct)))
  }
  scope :rooms_band, ->(r, delta = 1) {
    next all if r.blank?
    where(rooms: ([r.to_i - delta, 1].max)..(r.to_i + delta))
  }
end
