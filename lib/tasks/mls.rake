# frozen_string_literal: true

namespace :mls do
  desc 'Pull MLS listings from Topnlab into the MlsListing cache'
  task sync: :environment do
    result = MlsSync::TopnlabSyncService.new.call
    puts "MLS sync result: #{result.inspect}"
    puts "Total MlsListing rows: #{MlsListing.count}"
    puts "Recent priced rows:   #{MlsListing.priced.recent.count}"
  end

  desc 'Show counts of MLS listings by realty_type and deal_type'
  task stats: :environment do
    grouped = MlsListing.group(:realty_type, :deal_type).count
    if grouped.empty?
      puts 'No MlsListing rows yet. Run `bin/rake mls:sync` first.'
    else
      grouped.each { |(rt, dt), n| puts "  #{rt.ljust(10)} #{dt.ljust(6)} #{n}" }
    end
  end

  desc 'Delete MlsListing rows synced more than 90 days ago'
  task purge_stale: :environment do
    deleted = MlsListing.where('synced_at < ?', 90.days.ago).delete_all
    puts "Deleted #{deleted} stale MlsListing rows."
  end
end
