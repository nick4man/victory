# frozen_string_literal: true

namespace :valuation do
  desc 'Run a sample valuation: bin/rake "valuation:test[Кострома Советская 1,60,2,apartment]"'
  task :test, [:address, :area, :rooms, :property_type] => :environment do |_t, args|
    address = args[:address] || 'Кострома, ул. Советская, 1'
    area = (args[:area] || 60).to_f
    rooms = (args[:rooms] || 2).to_i
    pt = args[:property_type] || 'apartment'

    valuation = PropertyValuation.new(
      property_type: pt, deal_type: 'sale',
      address: address, total_area: area, rooms: rooms,
      floor: 5, total_floors: 9, building_year: 2010,
      property_condition: 'good',
      name: 'CLI test', phone: '+70000000000'
    )
    valuation.send(:resolve_coordinates)

    puts "Address: #{address}"
    puts "Geocoded: lat=#{valuation.latitude}, lng=#{valuation.longitude} (city=#{valuation.city}, district=#{valuation.district})"

    result = PropertyEvaluationService.new(valuation).call

    if result[:success]
      puts ''
      puts "Tier: #{result[:tier]}  Confidence: #{(result[:confidence_level] * 100).round}%"
      puts "Estimated price:        #{result[:estimated_price]}"
      puts "Range:                  #{result[:min_price]} … #{result[:max_price]}"
      puts "Price/m² (base/adj):    #{result[:base_price_per_sqm]} → #{result[:price_per_sqm]}"
      puts "Adjustments:            #{result[:adjustments].inspect}"
      puts ''
      puts 'Comparables:'
      result[:comparables].each_with_index do |c, i|
        puts "  #{i + 1}. #{c[:title]} | #{c[:price]} ₽ | #{c[:price_per_sqm]}/м² | #{c[:distance_km] || '?'} км | #{c[:source]}"
      end
      puts ''
      puts "Market analysis: #{result[:market_analysis]}"
    else
      puts "Failure: #{result[:error]}"
    end
  end
end
