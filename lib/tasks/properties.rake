# frozen_string_literal: true

namespace :properties do
  desc 'Fill Property#district for rows where it is NULL — regex match against RyazanDistricts aliases'
  task backfill_districts: :environment do
    result = PropertyDistrictBackfillJob.new.perform
    puts "Backfill result: #{result.inspect}"

    by_district = Property.unscoped.where.not(district: [nil, '']).group(:district).count.sort_by { |_, n| -n }
    puts "\nDistribution after backfill (top 20):"
    by_district.first(20).each { |d, n| puts "  #{d.ljust(30)} #{n}" }

    null_count = Property.unscoped.where(district: [nil, '']).count
    puts "\nStill NULL: #{null_count}"
  end

  # Some Property rows came from the Topnlab CRM with addresses outside
  # of Ryazan — Moscow, SPb, Krasnodar, etc. They are real objects, but
  # they pollute the comparable pool for Ryazan valuations: when
  # ComparableFinder relaxes to tier 4 (city-level), foreign rows get
  # picked up and the model picks ₽/м² from a Moscow flat to value a
  # Ryazan one. Solution: unpublish anything more than 100 km from the
  # city center. They stay in the DB (re-publishable if needed) but don't
  # leak into valuations.
  desc 'Unpublish Property rows whose coordinates are 100+ km from Ryazan center'
  task hide_non_ryazan: :environment do
    ryazan_center = [54.625, 39.735]

    candidates = Property.unscoped
                         .where.not(latitude: nil, longitude: nil)
                         .where.not(published_at: nil)
                         .to_a

    far_away = candidates.select do |p|
      km = Geocoder::Calculations.distance_between(
        ryazan_center, [p.latitude.to_f, p.longitude.to_f], units: :km
      )
      km.to_f > 100
    end

    puts "Found #{far_away.size} non-Ryazan published Property rows."
    hidden = 0
    far_away.each do |p|
      km = Geocoder::Calculations.distance_between(
        ryazan_center, [p.latitude.to_f, p.longitude.to_f], units: :km
      ).to_f.round(1)
      puts "  ##{p.id} '#{p.address.to_s.truncate(60)}' — #{km} км — unpublished"
      p.update_columns(published_at: nil, status: :draft)
      hidden += 1
    end

    puts "\nDone. Unpublished: #{hidden}."
    puts "Property.published.count: #{Property.published.count}"
  end
end
