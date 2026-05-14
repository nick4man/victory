# frozen_string_literal: true

# Rake-команды для синхронизации stage_id маппинга Topnlab CRM.
# См. app/services/topnlab/stages_cache.rb для логики.
namespace :topnlab do
  namespace :stages do
    desc 'Refresh discovered stages list from Topnlab API (writes config/topnlab_stages.yml)'
    task refresh: :environment do
      count = Topnlab::StagesCache.refresh!
      puts "Discovered #{count} stages."
      puts "Now manually fill in `map:` section of config/topnlab_stages.yml"
      puts 'with the integer ids that match our internal stage_keys.'
      puts ''
      puts 'Discovered:'
      Topnlab::StagesCache.discovered.each do |s|
        puts "  id=#{s['id']}: #{s['name']}"
      end
    end

    desc 'Show current StagesCache.for_buyers mapping'
    task show: :environment do
      puts 'StagesCache.for_buyers:'
      Topnlab::StagesCache.for_buyers.each do |k, v|
        puts "  #{k.ljust(15)} → #{v}"
      end
      puts ''
      puts 'Discovered:'
      Topnlab::StagesCache.discovered.each do |s|
        puts "  id=#{s['id']}: #{s['name']}"
      end
    end
  end
end
