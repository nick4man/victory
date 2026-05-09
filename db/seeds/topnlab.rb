# frozen_string_literal: true

# Idempotent seed for Topnlab CRM integration:
# - 6 PropertyType records (slug = Topnlab realty_type values)
# - Fallback agent user that owns imported properties when CRM agent
#   email cannot be matched to an existing User.
#
# Run: docker compose exec web bin/rails runner db/seeds/topnlab.rb

puts '🌱 Topnlab seed: property types + fallback user'

property_types = [
  { slug: 'flat',     name: 'Квартиры',          icon: '🏢', position: 1 },
  { slug: 'room',     name: 'Комнаты',           icon: '🛏️', position: 2 },
  { slug: 'house',    name: 'Дома',              icon: '🏠', position: 3 },
  { slug: 'land',     name: 'Земельные участки', icon: '🌳', position: 4 },
  { slug: 'commerce', name: 'Коммерция',         icon: '🏪', position: 5 },
  { slug: 'garage',   name: 'Гаражи',            icon: '🚗', position: 6 }
]

property_types.each do |attrs|
  pt = PropertyType.find_or_initialize_by(slug: attrs[:slug])
  pt.assign_attributes(attrs.merge(active: true))
  pt.save!
  puts "  ✓ PropertyType #{attrs[:slug]}: #{pt.name}"
end

email = ENV.fetch('TOPNLAB_FALLBACK_USER_EMAIL', 'topnlab@viktory-realty.ru')
fallback = User.find_or_initialize_by(email: email)
if fallback.new_record?
  fallback.assign_attributes(
    first_name: 'Topnlab',
    last_name: 'Import',
    phone: '79000000000',
    role: 'agent',
    confirmed_at: Time.current,
    password: SecureRandom.hex(16)
  )
  fallback.save!
  puts "  ✓ Fallback user created: #{email} (role=agent)"
else
  puts "  • Fallback user already exists: #{email}"
end

puts "Done. Property types: #{PropertyType.count}, Users: #{User.count}"
