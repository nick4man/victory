# frozen_string_literal: true

# Phase 13 cleanup rake tasks — backfill skew после 5-фазного аудита.
#
# Использование:
#   docker compose exec web bin/rake phase13:diagnose      # read-only отчёт
#   docker compose exec web bin/rake phase13:backfill_roles # apply
#   docker compose exec web bin/rake phase13:all           # diagnose + backfill
namespace :phase13 do
  desc 'Diagnose — show counts that need backfill (no writes)'
  task diagnose: :environment do
    puts '=== Phase 13 cleanup diagnose ==='
    puts ''

    # Iter 31 — role/is_manager skew: pre-Iter-31 /promote @user manager
    # установил is_manager=true но НЕ role='manager' (оставлял role='agent').
    skew = TelegramUser.where(is_manager: true, role: 'agent')
    puts "[role enum skew]"
    puts "  is_manager=true + role='agent': #{skew.count}"
    skew.find_each do |u|
      puts "    #{u.mention} (id=#{u.id})"
    end
    puts ''

    # Iter 39 — metadata bloat check (LeadEvent с history > cap)
    bloat_keys = LeadEvent::HISTORY_DEFAULT_CAPS.keys
    puts "[metadata bloat — history > cap]"
    LeadEvent.where.not(metadata: nil).find_each do |le|
      bloat_keys.each do |key|
        arr = Array(le.metadata[key])
        cap = LeadEvent::HISTORY_DEFAULT_CAPS[key]
        if arr.size > cap
          puts "  LeadEvent##{le.id} metadata['#{key}'] size=#{arr.size} > cap=#{cap}"
        end
      end
    end
    puts ''

    puts '=== END diagnose ==='
  end

  desc 'Backfill role enum для users с is_manager=true но role=agent (Iter 31 fix)'
  task backfill_roles: :environment do
    puts '=== Phase 13 backfill: role enum (Iter 31) ==='
    skew = TelegramUser.where(is_manager: true, role: 'agent')
    count = skew.count
    if count.zero?
      puts 'Нечего бэкфилить — все is_manager=true users уже имеют role != agent.'
    else
      puts "Найдено #{count} users с is_manager=true, role='agent':"
      skew.find_each { |u| puts "  #{u.mention} (id=#{u.id})" }
      print 'Применить (set role=manager)? [yes/N]: '
      answer = $stdin.gets.to_s.strip.downcase
      if answer == 'yes'
        updated = skew.update_all(role: 'manager') # rubocop:disable Rails/SkipsModelValidations
        puts "✅ Updated #{updated} rows. role='manager' установлен."
      else
        puts '✖️ Отменено. Ничего не изменено.'
      end
    end
    puts ''
  end

  desc 'Prune metadata arrays > cap для LeadEvent (Iter 39 fix retroactive)'
  task prune_metadata: :environment do
    puts '=== Phase 13 backfill: metadata pruning (Iter 39) ==='
    bloat_keys = LeadEvent::HISTORY_DEFAULT_CAPS.keys
    affected = []
    LeadEvent.where.not(metadata: nil).find_each do |le|
      changes = {}
      bloat_keys.each do |key|
        arr = Array(le.metadata[key])
        cap = LeadEvent::HISTORY_DEFAULT_CAPS[key]
        if arr.size > cap
          changes[key] = arr.last(cap)
        end
      end
      next if changes.empty?

      affected << [le.id, changes.transform_values(&:size)]
      le.update!(metadata: le.metadata.merge(changes))
    end
    if affected.empty?
      puts 'Нечего обрезать — все metadata arrays в пределах caps.'
    else
      puts "Обрезано #{affected.size} LeadEvent'ов:"
      affected.each { |id, sizes| puts "  LeadEvent##{id} → #{sizes.inspect}" }
    end
    puts ''
  end

  desc 'Run all cleanup tasks (diagnose + backfill + prune)'
  task all: %i[diagnose backfill_roles prune_metadata] do
    puts '=== Phase 13 cleanup all DONE ==='
  end
end
