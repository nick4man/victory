# frozen_string_literal: true

# Fills in Property#district by matching the address string against the
# aliases catalogued in RyazanDistricts. Cheap and deterministic: no API
# calls, no geocoding round-trips — pure regex on `address` (case-folded).
#
# Why regex over geocoder reverse-lookup: DaData / Yandex Geo APIs return
# the formal administrative district ("Октябрьский") but not the народный
# micro-district that users actually search for ("Канищево"). Our aliases
# map both names from one source of truth (RyazanDistricts::MICRO).
#
# Idempotent — running it twice is a no-op; we only touch rows where
# district IS NULL or blank.
class PropertyDistrictBackfillJob < ApplicationJob
  queue_as :low_priority

  def perform
    return Rails.logger.info('[PropertyDistrictBackfill] RyazanDistricts not loaded') unless defined?(RyazanDistricts)

    aliases = build_alias_map  # alias_lowercased => district_name
    scope = Property.unscoped.where(deleted_at: nil).where(district: [nil, ''])
    total = scope.count
    filled = 0
    skipped = 0

    scope.find_each do |property|
      addr = property.address.to_s.downcase
      match = aliases.find { |alias_lc, _| addr.include?(alias_lc) }
      if match
        property.update_column(:district, match[1])
        filled += 1
      else
        skipped += 1
      end
    end

    Rails.logger.info("[PropertyDistrictBackfill] total=#{total} filled=#{filled} skipped=#{skipped}")
    { total: total, filled: filled, skipped: skipped }
  end

  private

  # Build {alias_downcased => canonical_micro_name}. Longer aliases first
  # so «Дашково-Песочня» matches before standalone «Песочня» (which is one
  # of its aliases). This avoids picking a too-generic shorter match when
  # the address actually contains the full district name.
  def build_alias_map
    pairs = RyazanDistricts::MICRO.flat_map do |_slug, meta|
      meta[:aliases].map { |a| [a.to_s.downcase, meta[:name]] }
    end
    pairs.sort_by { |alias_lc, _| -alias_lc.length }.to_h
  end
end
