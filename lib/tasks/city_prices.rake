# frozen_string_literal: true

namespace :city_prices do
  desc 'Re-seed city_median_prices from db/seeds/city_median_prices.rb (idempotent)'
  task reseed: :environment do
    load Rails.root.join('db/seeds/city_median_prices.rb')
    puts "Done. Total: #{CityMedianPrice.count} rows."
  end

  desc 'Show median ₽/м² for a given city (rake city_prices:show[Москва])'
  task :show, [:city] => :environment do |_t, args|
    city = args[:city].to_s
    if city.empty?
      puts 'Usage: rake city_prices:show[Москва]'
      exit 1
    end
    rows = CityMedianPrice.where('city ILIKE ?', city).order(:property_type)
    if rows.empty?
      puts "No rows for '#{city}'."
    else
      puts "#{rows.first.city} (#{rows.first.as_of}, #{rows.first.source}):"
      rows.each { |r| puts "  #{r.property_type.ljust(12)} #{r.median_price_per_sqm.to_s.rjust(7)} ₽/м²" }
    end
  end
end
