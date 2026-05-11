# frozen_string_literal: true

# Rake interface for Topnlab CRM integration.
#
# Examples:
#   docker compose exec web bin/rake topnlab:test
#   docker compose exec web bin/rake topnlab:options
#   docker compose exec web bin/rake topnlab:import_all
#   docker compose exec web bin/rake topnlab:import_one[123]
namespace :topnlab do
  desc 'Smoke-test: ping API, list users, fetch sample IDs and one entity'
  task test: :environment do
    client = Topnlab::Client.new

    puts "→ get_users"
    users = client.get_users
    puts "  Users count: #{users.size}"
    if (sample = users.first)
      keys = %w[id firstname lastname email phone_num role_name department_title status]
      view = sample.select { |k, _| keys.include?(k.to_s) }
      puts "  Sample user: #{view.inspect}"
    end

    puts "\n→ get_ids(type=realty, action=sale, realty_type=flat, in_ad=true)"
    ids = client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat', in_ad: true)
    puts "  IDs returned: #{ids.size}"
    puts "  First 10: #{ids.first(10).inspect}"

    if ids.any?
      puts "\n→ get_entities(#{ids.first})"
      entities = client.get_entities([ids.first], type: 'realty')
      payload = entities.values.first
      if payload
        puts "  Top-level keys (#{payload.keys.size}):"
        payload.keys.sort.each_slice(6) { |slice| puts "    #{slice.inspect}" }
        puts "\n  Sample raw payload (truncated 4 KB):"
        puts JSON.pretty_generate(payload).first(4000)
      end
    end
  end

  desc 'Print /realty/getoptions reference (default field options)'
  task options: :environment do
    client = Topnlab::Client.new
    options = client.get_realty_options
    puts JSON.pretty_generate(options).first(8000)
  end

  desc 'Synchronous full import from Topnlab feed'
  task import_all: :environment do
    require_relative '../../app/services/topnlab/importer' rescue nil
    result = Topnlab::Importer.new.call
    puts "Result: #{result.inspect}"
  end

  desc 'Refresh Topnlab counts cache (counts per state for realty + orders) — synchronous, ~8 min'
  task refresh_stats: :environment do
    Topnlab::StatsClient.bust!
    AgencyMetricsService.bust!
    stats = Topnlab::StatsClient.compute_now!
    puts "realty_total=#{stats[:realty_total]} (per state: #{stats[:realty_per_state].inspect})"
    puts "order_total=#{stats[:order_total]} (per state: #{stats[:order_per_state].inspect})"
    puts "processed_total=#{stats[:processed_total]}"
    puts "closed_deals=#{stats[:closed_deals]}"
    puts "stale=#{stats[:stale]}"
  end

  desc 'Backfill all completed deals (deal_state=deal) from Topnlab + bust metrics cache'
  task backfill_completed: :environment do
    require_relative '../../app/services/topnlab/importer' rescue nil
    result = Topnlab::Importer.new(filter: { deal_state: Topnlab::Importer::COMPLETED_STATES }).call
    completed = Property.unscoped.where(deal_state: 'deal').count
    volume    = Property.unscoped.where(deal_state: 'deal').sum(:price).to_i
    puts "Result: #{result.inspect}"
    puts "Now Property.where(deal_state='deal').count = #{completed}"
    puts "Total volume RUB = #{volume}"
    AgencyMetricsService.bust!
    puts AgencyMetricsService.call.inspect
  end

  desc 'Import a single object by Topnlab id'
  task :import_one, [:id] => :environment do |_t, args|
    raise 'Usage: rake topnlab:import_one[ID]' if args[:id].blank?
    require_relative '../../app/services/topnlab/importer' rescue nil
    client = Topnlab::Client.new
    payload = client.get_entities([args[:id]], type: 'realty').values.first
    if payload.nil?
      puts "No entity #{args[:id]}"
      next
    end
    puts "Fetched id=#{payload['id']}, address=#{payload['address']}"
    Topnlab::Importer.new.import_payload(payload)
    puts "Property.count = #{Property.count}"
  end

  desc 'Sync company structure (departments + users) from Topnlab'
  task staff_sync: :environment do
    result = Topnlab::StaffSyncService.new.call
    puts "Result: #{result.inspect}"
    puts "Department.count = #{Department.count}"
    puts "User.synced_from_crm.count = #{User.synced_from_crm.count}"
    puts "User.chiefs.count = #{User.chiefs.count}"
  end

  desc 'Print get-event-types справочник для Activity Log'
  task event_types: :environment do
    client = Topnlab::Client.new
    types = client.get_event_types
    puts JSON.pretty_generate(types).first(8000)
  end

  desc 'Sync buyer/renter orders (type=order) from Topnlab into BuyerOrder'
  task orders_sync: :environment do
    result = Topnlab::OrdersImporter.new.call
    puts "Result: #{result.inspect}"
    puts "BuyerOrder.count = #{BuyerOrder.count}"
    puts "BuyerOrder.active.count = #{BuyerOrder.active.count}"
  end

  desc 'Re-fetch in_ad / in_mls flags from Topnlab for all imported properties + bust metrics cache'
  task refresh_ad_flags: :environment do
    ids = Property.unscoped.where(external_source: 'topnlab').pluck(:external_id).compact
    if ids.empty?
      puts 'No Topnlab properties found.'
      next
    end

    client = Topnlab::Client.new
    was = Property.unscoped.where(external_source: 'topnlab')
                  .where('in_ad = TRUE OR in_mls = TRUE').count
    updated = 0

    ids.each_slice(300) do |chunk|
      payloads = client.get_entities(chunk, type: 'realty')
      payloads.each_value do |payload|
        next unless payload.is_a?(Hash)
        prop = Property.unscoped.find_by(external_source: 'topnlab', external_id: payload['id'].to_s)
        next unless prop
        prop.update_columns(
          in_ad:  payload['in_ad']  == true,
          in_mls: payload['in_mls'] == true
        )
        updated += 1
      end
      print '.'
    end
    puts
    now = Property.unscoped.where(external_source: 'topnlab')
                  .where('in_ad = TRUE OR in_mls = TRUE').count
    n_ad  = Property.unscoped.where(external_source: 'topnlab', in_ad: true).count
    n_mls = Property.unscoped.where(external_source: 'topnlab', in_mls: true).count
    puts "Updated: #{updated}"
    puts "Advertising (in_ad OR in_mls): #{now} (было: #{was})"
    puts "  breakdown: in_ad=true → #{n_ad}, in_mls=true → #{n_mls}"
    AgencyMetricsService.bust! if defined?(AgencyMetricsService)
  end

  # Kept as alias for backward compatibility with existing scripts/docs.
  task refresh_in_ad: :refresh_ad_flags

  desc 'Re-derive area / land_area_m2 / price_per_sqm for all Topnlab properties'
  task refresh_areas: :environment do
    ids = Property.unscoped.where(external_source: 'topnlab').pluck(:external_id).compact
    if ids.empty?
      puts 'No Topnlab properties found.'
      next
    end

    client = Topnlab::Client.new
    types  = PropertyType.all.index_by(&:slug)
    updated = 0
    skipped = 0
    ids.each_slice(300) do |chunk|
      payloads = client.get_entities(chunk, type: 'realty')
      payloads.each_value do |payload|
        next unless payload.is_a?(Hash)
        prop = Property.unscoped.find_by(external_source: 'topnlab', external_id: payload['id'].to_s)
        next unless prop

        attrs = Topnlab::PropertyMapper.new(payload, {}, types).to_attributes
        unless attrs
          skipped += 1
          next
        end

        prop.update_columns(
          area:          attrs[:area],
          land_area_m2:  attrs[:land_area_m2],
          price_per_sqm: attrs[:price_per_sqm],
          title:         attrs[:title]
        )
        updated += 1
      end
      print '.'
    end
    puts
    puts "Updated: #{updated}, skipped: #{skipped}"
    puts 'Now run: docker compose exec web bin/rake embeddings:backfill'
  end
end
