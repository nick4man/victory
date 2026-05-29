# frozen_string_literal: true

namespace :seo_generation do
  namespace :property_meta do
    desc 'Generate SEO meta for all active properties without it. Args: ' \
         '[limit] (default 200), [delay] secs between enqueues (default 0.5)'
    task :backfill, %i[limit delay] => :environment do |_t, args|
      limit = (args[:limit] || 200).to_i.clamp(1, 5000)
      delay = (args[:delay] || 0.5).to_f.clamp(0.1, 5.0)

      pending = Property
                .where(status: :active, seo_generated_at: nil)
                .order(updated_at: :desc)
                .limit(limit)

      total = pending.count
      puts "Seo backfill: #{total} pending properties (limit=#{limit}, delay=#{delay}s)"

      if total.zero?
        puts 'Nothing to do — all active properties have seo_generated_at set.'
        next
      end

      pending.find_each do |property|
        Seo::GeneratePropertyMetaJob.perform_later(property.id)
        print '.'
        sleep delay
      end

      puts ''
      puts "Enqueued #{total} jobs to :low_priority. Watch with " \
           '`tail -f log/development.log | grep Seo::GeneratePropertyMetaJob`.'
    end

    desc 'Re-generate SEO meta for one property by id. Usage: ' \
         'rake "seo_generation:property_meta:regenerate[42]"'
    task :regenerate, [:id] => :environment do |_t, args|
      id = args[:id].to_i
      abort 'Usage: rake "seo_generation:property_meta:regenerate[<id>]"' if id.zero?

      property = Property.unscoped.find_by(id: id)
      abort "Property ##{id} not found" if property.nil?

      result = Seo::PropertyMetaGenerator.new(property).persist!

      if result.ok?
        puts "OK property=#{property.id} model=#{result.model}"
        puts "  title:       #{result.title}"
        puts "  description: #{result.description}"
        puts "  h1:          #{result.h1}"
      else
        warn "FAIL property=#{property.id} error=#{result.error}"
        exit 1
      end
    end

    desc 'Stats: how many properties have generated SEO meta'
    task stats: :environment do
      active = Property.where(status: :active).count
      with_meta = Property.where(status: :active).where.not(seo_generated_at: nil).count
      pct = active.positive? ? (with_meta * 100.0 / active).round(1) : 0

      puts "Active properties:     #{active}"
      puts "With SEO meta:         #{with_meta}"
      puts "Coverage:              #{pct}%"

      models = Property.where(status: :active)
                       .where.not(seo_model: nil)
                       .group(:seo_model)
                       .count
      if models.any?
        puts ''
        puts 'Model distribution:'
        models.sort_by { |_m, c| -c }.each { |m, c| puts "  #{c.to_s.rjust(5)}  #{m}" }
      end
    end
  end
end
