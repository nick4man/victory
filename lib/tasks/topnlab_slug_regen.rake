# frozen_string_literal: true

# P4-followup of «Fix mis-tagged Студия» plan.
#
# После backfill `topnlab:remap_rooms` (commit 28d3073) title исправлен,
# но slug остался прежним (`studiya-…`) — friendly_id регенерирует slug
# только при `should_generate_new_friendly_id? == true`, что по умолчанию
# срабатывает только для новых записей.
#
# Эта задача forces регенерацию: для properties где slug стал stale
# относительно нового title — set slug=nil + save → friendly_id callback
# построит новый slug из текущего title. Старый slug автомат уходит в
# friendly_id_slugs history → 301 redirect для backlinks/Yandex/Google.
#
# Usage:
#   bin/rake topnlab:slug_regen DRY_RUN=true        # log candidates only
#   bin/rake topnlab:slug_regen                     # apply
#   bin/rake topnlab:slug_regen IDS=49,47,21         # specific
#
# Criterion: slug starts with «studiya-» BUT title не начинается со
# «Студия» (case-insensitive). Это покрывает 30 properties из backfill.
namespace :topnlab do
  desc 'Force-regenerate stale slugs after rooms/title backfill'
  task slug_regen: :environment do
    dry_run   = ENV['DRY_RUN'].to_s == 'true'
    id_filter = ENV['IDS'].to_s.split(/[,\s]+/).map(&:strip).reject(&:blank?).map(&:to_i)

    scope = Property.unscoped
                    .where(external_source: 'topnlab')
                    .where('slug LIKE ?', 'studiya-%')
                    .where.not('LOWER(title) LIKE ?', 'студия%')
    scope = scope.where(id: id_filter) if id_filter.any?

    candidates = scope.to_a
    if candidates.empty?
      puts 'No stale slugs found (all studiya-* slugs match Студия titles, or no Topnlab props).'
      next
    end

    puts "[topnlab:slug_regen] dry_run=#{dry_run} candidates=#{candidates.size}"

    stats = { regenerated: 0, unchanged: 0, errors: 0 }

    candidates.each do |prop|
      old_slug = prop.slug
      puts "  property=#{prop.id} title=#{prop.title.truncate(60).inspect}"
      puts "    old_slug=#{old_slug.inspect}"

      next if dry_run

      begin
        # nil + save заставит friendly_id вызвать set_slug -> slug_candidates.
        # use: %i[history] автоматом запишет старый slug в friendly_id_slugs.
        prop.slug = nil
        prop.save(validate: false)
        new_slug = prop.reload.slug
        if new_slug == old_slug
          puts "    [WARN] slug не изменился — friendly_id_slugs возможно блокирует уникальность"
          stats[:unchanged] += 1
        else
          puts "    new_slug=#{new_slug.inspect}"
          stats[:regenerated] += 1
        end
      rescue StandardError => e
        stats[:errors] += 1
        puts "    [error] #{e.class}: #{e.message.truncate(200)}"
      end
    end

    puts "\n[topnlab:slug_regen] DONE: #{stats}"
    puts '(DRY_RUN — no writes)' if dry_run
  end
end
