# frozen_string_literal: true

# Backfill Property.commercial_type для существующих commerce объявлений.
# Использование:
#   rake commercial_types:backfill            # все commerce без commercial_type
#   rake 'commercial_types:backfill[force]'   # перезаписать даже если уже задан
#   rake commercial_types:reclassify[ID]      # одна конкретная property
#   rake commercial_types:stats               # распределение по типам
namespace :commercial_types do
  desc 'Classify commercial_type для всех commerce-объявлений через LLM'
  task :backfill, %i[force] => :environment do |_, args|
    force = args[:force].to_s == 'force'
    scope = Property.unscoped.joins(:property_type).where(property_types: { slug: 'commerce' })
    scope = scope.where(commercial_type: nil) unless force
    total = scope.count
    if total.zero?
      puts '[commercial_types:backfill] нет объявлений для classify'
      next
    end

    puts "[commercial_types:backfill] classify #{total} commerce-объявлений..."
    distribution = Hash.new(0)
    processed = 0
    scope.find_each do |p|
      result = Property::CommercialTypeClassifier.call(p)
      if result.present? && result != p.commercial_type
        p.update_columns(commercial_type: result, updated_at: Time.current)
      end
      distribution[result] += 1
      processed += 1
      print "\r  processed #{processed}/#{total}"
      $stdout.flush
    end
    puts ''
    puts ''
    puts 'Distribution:'
    distribution.sort_by { |_, n| -n }.each { |t, n| puts "  #{n.to_s.rjust(4)} × #{t}" }
  end

  desc 'Re-classify конкретный property — для debug или manual override'
  task :reclassify, %i[id] => :environment do |_, args|
    id = args[:id].to_i
    p = Property.unscoped.find_by(id: id)
    return puts "[commercial_types:reclassify] property id=#{id} не найден" unless p

    result = Property::CommercialTypeClassifier.call(p)
    p.update_columns(commercial_type: result, updated_at: Time.current)
    puts "[commercial_types:reclassify] property #{id} (#{p.external_id}): #{result}"
  end

  desc 'Stats — распределение commercial_type по commerce-объявлениям'
  task stats: :environment do
    counts = Property.unscoped
                     .joins(:property_type)
                     .where(property_types: { slug: 'commerce' })
                     .group(:commercial_type)
                     .count
    total = counts.values.sum
    puts "Total commerce objects: #{total}"
    counts.sort_by { |_, n| -n }.each do |t, n|
      puts "  #{n.to_s.rjust(4)} × #{(t.presence || '(nil)').to_s}"
    end
  end
end
