# frozen_string_literal: true

# Pre-generates all Active Storage variants declared on Property#images so
# the first crawler hit doesn't pay the libvips processing cost. Should be
# run as part of the deploy pipeline after attachments change.
#
# Variants are uniquely keyed by their transformation hash, so re-running
# is cheap — only NEW variants get processed.
namespace :assets do
  desc 'Pre-generate all Property image variants (idempotent)'
  task pregenerate_property_variants: :environment do
    variants = %i[thumb thumb_webp card card_webp hero hero_webp]
    total_props = Property.unscoped.count
    processed_count = 0
    errored_count   = 0

    Property.unscoped.find_each.with_index(1) do |property, i|
      next unless property.images.attached?

      property.images.each do |image|
        variants.each do |key|
          # `.processed` is idempotent: a cache hit returns immediately,
          # a miss runs libvips. So we always call it and trust the lookup.
          image.variant(key).processed
          processed_count += 1
        rescue StandardError => e
          errored_count += 1
          warn "[##{property.id} blob=#{image.blob.id} #{key}] #{e.class}: #{e.message}"
        end
      end

      puts "  [#{i}/#{total_props}] #{property.slug || property.id}" if (i % 10).zero?
    end

    puts ''
    puts "Done. processed_or_cached=#{processed_count} errored=#{errored_count}"
  end
end
