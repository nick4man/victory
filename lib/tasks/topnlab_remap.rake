# frozen_string_literal: true

# Backfill для P3 of «Fix mis-tagged Студия» plan.
#
# Перезатягивает payload из Topnlab для всех existing Topnlab-properties
# и re-applies `PropertyMapper#to_attributes` чтобы получить корректные
# `rooms` + `title`. Slug регенерируется автоматом FriendlyId callback'ом
# при `title` изменении; old slug отправляется в friendly_id_slugs
# history → 301 redirect.
#
# Usage:
#   bin/rake topnlab:remap_rooms                    # apply changes
#   bin/rake topnlab:remap_rooms DRY_RUN=true       # log diffs only
#   bin/rake topnlab:remap_rooms LIMIT=5            # process only 5
#   bin/rake topnlab:remap_rooms IDS=49,47,21       # specific properties
#
# Safety:
#   - НЕ трогает: status, published_at, signed_agency_contract_at,
#     deal_state, owner_user_id, in_ad, in_mls
#   - Использует `assign_attributes` + `save(validate: false)` чтобы
#     избежать validation noise на legacy data
#   - `get_entities` батчит до 300 IDs за раз → один API-call для 101
#     property, throttle отрабатывает за нас
#
# Recovery: friendly_id с :history — старые slugs резолвятся редиректом.
namespace :topnlab do
  desc 'Re-map rooms+title из свежего Topnlab payload для existing properties'
  task remap_rooms: :environment do
    dry_run = ENV['DRY_RUN'].to_s == 'true'
    limit   = ENV['LIMIT']&.to_i
    id_filter = ENV['IDS'].to_s.split(/[,\s]+/).map(&:strip).reject(&:blank?).map(&:to_i)

    scope = Property.unscoped
                    .where(external_source: 'topnlab')
                    .where.not(external_id: nil)
    scope = scope.where(id: id_filter)         if id_filter.any?
    scope = scope.limit(limit)                 if limit&.positive?

    properties = scope.to_a
    if properties.empty?
      puts 'No Topnlab properties matched. Nothing to do.'
      next
    end

    puts "[topnlab:remap_rooms] dry_run=#{dry_run} candidates=#{properties.size}"

    ext_ids = properties.map { |p| p.external_id.to_i }.uniq
    puts "[topnlab:remap_rooms] fetching #{ext_ids.size} payloads from Topnlab…"
    payloads = Topnlab::Client.new.get_entities(ext_ids)
    puts "[topnlab:remap_rooms] received #{payloads.size} payloads"

    agents_index = User.where.not(email: nil).pluck(:id, :email)
                       .each_with_object({}) { |(id, em), h| h[em.to_s.downcase] = id }
    type_index = PropertyType.all.index_by(&:slug)

    stats = { updated: 0, unchanged: 0, missing_payload: 0, errors: 0 }

    properties.each do |prop|
      payload = payloads[prop.external_id.to_s] || payloads[prop.external_id.to_i]
      if payload.blank?
        stats[:missing_payload] += 1
        puts "  [skip] property=#{prop.id} ext=#{prop.external_id}: no payload returned"
        next
      end

      mapper = Topnlab::PropertyMapper.new(payload, agents_index, type_index)
      new_attrs = mapper.to_attributes
      if new_attrs.nil?
        stats[:missing_payload] += 1
        next
      end

      rooms_was, rooms_now = prop.rooms, new_attrs[:rooms]
      title_was, title_now = prop.title, new_attrs[:title]

      if rooms_was == rooms_now && title_was == title_now
        stats[:unchanged] += 1
        next
      end

      puts "  property=#{prop.id} ext=#{prop.external_id}"
      puts "    rooms: #{rooms_was.inspect} → #{rooms_now.inspect}"
      puts "    title: #{title_was.inspect.truncate(60)}"
      puts "         → #{title_now.inspect.truncate(60)}"

      next if dry_run

      begin
        # Точечный update — only rooms/title. FriendlyId callbacks
        # выполнятся при save и регенерируют slug (плюс history entry).
        prop.assign_attributes(rooms: rooms_now, title: title_now)
        prop.save(validate: false)
        stats[:updated] += 1
      rescue StandardError => e
        stats[:errors] += 1
        puts "    [error] #{e.class}: #{e.message.truncate(200)}"
      end
    end

    puts "\n[topnlab:remap_rooms] DONE: #{stats}"
    puts '(DRY_RUN — no writes; rerun без DRY_RUN=true для применения)' if dry_run
  end
end
