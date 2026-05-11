# frozen_string_literal: true

namespace :embeddings do
  desc 'Generate embeddings for every Property.in_advertising (synchronous, rate-limited)'
  task backfill: :environment do
    scope = Property.in_advertising
    total = scope.count
    puts "[embeddings:backfill] target=#{total} properties"

    done = 0
    skipped = 0
    failed = 0

    scope.find_each do |p|
      EmbedPropertyJob.perform_now(p.id)
      done += 1
      print "\r  progress: #{done}/#{total}" if (done % 5).zero?
      sleep 0.7 # ≈85 req/min — under Google free tier 100 RPM
    rescue StandardError => e
      failed += 1
      warn "\n  property=#{p.id} failed: #{e.class} #{e.message}"
    end

    puts "\n[embeddings:backfill] done=#{done} skipped=#{skipped} failed=#{failed}"
  end

  desc 'Re-embed properties whose content_hash is stale or missing'
  task refresh_stale: :environment do
    embedded_ids = PropertyEmbedding.pluck(:property_id).to_set
    stale = Property.in_advertising.find_each.reject { |p| embedded_ids.include?(p.id) }
    puts "[embeddings:refresh_stale] missing=#{stale.size}"
    stale.each { |p| EmbedPropertyJob.perform_later(p.id) }
  end

  desc 'Backfill embeddings for every published Article (Phase 7)'
  task articles: :environment do
    total = Article.public_facing.count
    puts "[embeddings:articles] enqueueing for #{total} published articles"
    Article.public_facing.find_each(batch_size: 50) do |a|
      EmbedArticleJob.perform_later(a.id)
    end
    puts '[embeddings:articles] done — check Sidekiq queue:low_priority'
  end
end
