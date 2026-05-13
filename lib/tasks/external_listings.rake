# frozen_string_literal: true

namespace :external_listings do
  desc 'Parse a single YRL feed URL. Usage: rake external_listings:sync_yrl[https://agency.ru/feed.xml]'
  task :sync_yrl, [:url] => :environment do |_t, args|
    if args[:url].blank?
      puts 'Usage: rake external_listings:sync_yrl[https://agency.ru/feed.xml]'
      exit 1
    end

    result = ExternalListings::YrlParser.new(args[:url]).call
    puts "Feed parsed: #{result.inspect}"
    puts "Total active ExternalListing: #{ExternalListing.active.count}"
  end

  desc 'Iterate over all configured YRL feeds (ENV-driven) and refresh ExternalListings'
  task sync_all_feeds: :environment do
    urls = ENV.fetch('YRL_FEED_URLS', '').split(',').map(&:strip).reject(&:empty?)
    if urls.empty?
      puts 'No YRL_FEED_URLS configured in env. Set YRL_FEED_URLS="https://a.ru/x.xml,https://b.ru/y.xml"'
      exit 1
    end

    urls.each do |url|
      puts "→ #{url}"
      r = ExternalListings::YrlParser.new(url).call
      puts "  fetched=#{r[:fetched]} upserted=#{r[:upserted]} errors=#{r[:errors].size}"
    end
    puts "\nGrand total ExternalListing: #{ExternalListing.count}"
  end

  desc 'Show distribution of ExternalListings by source/property_type/deal_type'
  task stats: :environment do
    puts 'Active by source:'
    ExternalListing.active.group(:source).count.each { |s, n| puts "  #{s.ljust(20)} #{n}" }
    puts "\nBy property_type:"
    ExternalListing.active.group(:property_type).count.each { |t, n| puts "  #{t.to_s.ljust(15)} #{n}" }
    puts "\nBy deal_type:"
    ExternalListing.active.group(:deal_type).count.each { |d, n| puts "  #{d.to_s.ljust(8)} #{n}" }
  end
end
