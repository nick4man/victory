# frozen_string_literal: true

namespace :topnlab do
  desc 'Regenerate human-readable titles for CRM-imported properties (default: only fallback-titled)'
  task :backfill_titles, [:scope] => :environment do |_t, args|
    fakes = case args[:scope].to_s
            when 'all'      then Property.where.not(external_id: nil)
            when 'studio'   then Property.where("title LIKE ?", "Студия %")
            else Property.where("title LIKE ?", "Объект %")
            end
    puts "Found #{fakes.count} properties to retitle (scope=#{args[:scope] || 'fallback'})"

    client = Topnlab::Client.new
    fakes.find_each do |property|
      payload = client.get_entities([property.external_id], type: 'realty').values.first
      next unless payload

      attrs = Topnlab::PropertyMapper.new(payload).to_attributes
      next unless attrs && attrs[:title].present?
      next if attrs[:title] == property.title

      old_title = property.title
      property.update_columns(title: attrs[:title], updated_at: Time.current)
      puts "  ##{property.id}: #{old_title} → #{attrs[:title]}"
    end
    puts 'Done.'
  end

  desc 'Re-trigger photo sync for properties without images'
  task backfill_photos: :environment do
    properties = Property.unscoped.left_joins(:images_attachments)
                         .where(active_storage_attachments: { id: nil })
                         .where.not(external_id: nil)
    puts "Found #{properties.count} properties without images"

    client = Topnlab::Client.new
    properties.find_each do |property|
      payload = client.get_entities([property.external_id], type: 'realty').values.first
      next unless payload

      urls = Topnlab::PropertyMapper.new(payload).photo_urls
      if urls.any?
        TopnlabPhotoSyncJob.perform_later(property.id, urls)
        puts "  Queued ##{property.id} (#{property.external_id}): #{urls.size} photos"
      else
        puts "  ##{property.id} (#{property.external_id}): no photos in CRM"
      end
    end
    puts 'Done. Check sidekiq queue for progress.'
  end
end
