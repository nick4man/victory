# frozen_string_literal: true

namespace :seo do
  desc 'Regenerate Property slugs using transliterated FriendlyId candidates'
  task regenerate_property_slugs: :environment do
    total    = Property.unscoped.count
    updated  = 0
    same     = 0
    errored  = 0

    Property.unscoped.find_each do |property|
      old_slug = property.slug
      property.slug = nil
      if property.save(validate: false)
        if property.slug == old_slug
          same += 1
        else
          updated += 1
        end
      else
        errored += 1
        warn "Property##{property.id}: #{property.errors.full_messages.join('; ')}"
      end
    end

    puts "Done. total=#{total} updated=#{updated} unchanged=#{same} errored=#{errored}"
  end
end
