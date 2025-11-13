# frozen_string_literal: true

# This file should contain all the record creation needed to seed the database
# with its default values. Data can then be loaded with:
# rails db:seed or rails db:setup

puts '🌱 Starting database seeding...'

# ==========================================
# Clean existing data (development only)
# ==========================================
if Rails.env.development?
  puts '🗑️  Cleaning existing data...'
  PropertyView.delete_all
  Favorite.delete_all
  SavedSearch.delete_all
  Message.delete_all
  Review.delete_all
  Inquiry.delete_all
  Property.delete_all
  User.delete_all
  puts '✅ Data cleaned'
end

# ==========================================
# Create Admin User
# ==========================================
puts '👤 Creating admin user...'

admin = User.create!(
  email: 'admin@viktory-realty.ru',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Администратор',
  last_name: 'Системы',
  phone: '+7 (999) 123-45-67',
  role: 'admin',
  confirmed_at: Time.current
)

puts "✅ Admin created: #{admin.email}"

# ==========================================
# Create Manager User
# ==========================================
puts '👤 Creating manager user...'

manager = User.create!(
  email: 'manager@viktory-realty.ru',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Иван',
  last_name: 'Менеджеров',
  phone: '+7 (999) 234-56-78',
  role: 'manager',
  confirmed_at: Time.current
)

puts "✅ Manager created: #{manager.email}"

# ==========================================
# Create Test Users
# ==========================================
puts '👥 Creating test users...'

users = []
5.times do |i|
  user = User.create!(
    email: "user#{i + 1}@example.com",
    password: 'password123',
    password_confirmation: 'password123',
    first_name: ['Александр', 'Мария', 'Дмитрий', 'Елена', 'Сергей'][i],
    last_name: ['Иванов', 'Петрова', 'Сидоров', 'Козлова', 'Смирнов'][i],
    phone: "+7 (999) #{100 + i}00-00-#{i}#{i}",
    role: 'user',
    confirmed_at: Time.current
  )
  users << user
end

puts "✅ Created #{users.count} test users"

# ==========================================
# Create Properties
# ==========================================
puts '🏠 Creating properties...'

# Moscow districts
districts = [
  'Центральный', 'Северный', 'Северо-Восточный', 'Восточный',
  'Юго-Восточный', 'Южный', 'Юго-Западный', 'Западный',
  'Северо-Западный', 'Зеленоградский'
]

metro_stations = [
  'Арбатская', 'Чистые пруды', 'Кропоткинская', 'Парк культуры',
  'Сокол', 'Аэропорт', 'ВДНХ', 'Алексеевская',
  'Таганская', 'Павелецская', 'Измайловская', 'Щёлковская',
  'Текстильщики', 'Кузьминки', 'Царицыно', 'Каширская',
  'Юго-Западная', 'Проспект Вернадского', 'Крылатское', 'Молодёжная'
]

property_types = ['apartment', 'house', 'townhouse', 'land', 'commercial']
deal_types = ['sale', 'rent']
conditions = ['excellent', 'good', 'satisfactory', 'needs_renovation']
statuses = ['active', 'active', 'active', 'pending']  # More active

properties = []

50.times do |i|
  property_type = property_types.sample
  deal_type = deal_types.sample
  
  # Generate realistic data based on type
  case property_type
  when 'apartment'
    area = rand(30..150)
    rooms = [1, 1, 2, 2, 2, 3, 3, 3, 4, 5].sample
    floor = rand(1..25)
    total_floors = rand(floor..25)
    price = deal_type == 'sale' ? area * rand(150_000..350_000) : area * rand(800..2000)
    
  when 'house'
    area = rand(80..400)
    rooms = rand(3..8)
    floor = 1
    total_floors = rand(1..3)
    land_area = rand(3..25) # sotki
    price = deal_type == 'sale' ? area * rand(120_000..250_000) : area * rand(600..1500)
    
  when 'townhouse'
    area = rand(100..250)
    rooms = rand(3..6)
    floor = 1
    total_floors = rand(2..3)
    land_area = rand(2..8)
    price = deal_type == 'sale' ? area * rand(130_000..280_000) : area * rand(700..1800)
    
  when 'land'
    area = rand(6..50) # sotki
    rooms = nil
    floor = nil
    total_floors = nil
    price = deal_type == 'sale' ? area * rand(100_000..500_000) : area * rand(5000..15000)
    
  when 'commercial'
    area = rand(50..500)
    rooms = nil
    floor = rand(1..10)
    total_floors = rand(floor..20)
    price = deal_type == 'sale' ? area * rand(250_000..600_000) : area * rand(1500..5000)
  end
  
  district = districts.sample
  metro = metro_stations.sample
  
  property = Property.create!(
    title: "#{I18n.t("property_types.#{property_type}")} #{area} м² в районе #{district}",
    description: "Отличный #{I18n.t("property_types.#{property_type}")} в #{district} районе. #{deal_type == 'sale' ? 'Продается' : 'Сдается'} в #{I18n.t("property_conditions.#{conditions.sample}")} состоянии. " \
                 "#{property_type == 'apartment' ? "#{rooms}-комнатная квартира" : property_type == 'house' ? "Дом с участком #{land_area} соток" : ""} " \
                 "Развитая инфраструктура, удобная транспортная доступность.",
    property_type: property_type,
    deal_type: deal_type,
    price: price,
    area: area,
    rooms: rooms,
    floor: floor,
    total_floors: total_floors,
    address: "Москва, #{district} район, ул. #{['Ленина', 'Пушкина', 'Чехова', 'Горького', 'Тверская'][i % 5]}, д. #{rand(1..100)}",
    district: district,
    metro_station: metro,
    metro_distance: rand(3..20),
    condition: conditions.sample,
    year_built: rand(1970..2023),
    status: statuses.sample,
    views_count: rand(0..500),
    latitude: 55.751244 + rand(-0.3..0.3),
    longitude: 37.618423 + rand(-0.3..0.3),
    amenities: ['parking', 'elevator', 'balcony', 'furniture', 'appliances', 'internet', 'security'].sample(rand(2..5))
  )
  
  properties << property
  print '.'
end

puts "\n✅ Created #{properties.count} properties"

# ==========================================
# Create Inquiries
# ==========================================
puts '📝 Creating inquiries...'

inquiry_types = ['viewing', 'callback', 'consultation', 'mortgage', 'property_selection']
inquiry_statuses = ['pending', 'in_progress', 'completed']

inquiries = []
30.times do
  inquiry = Inquiry.create!(
    user: users.sample,
    property: [properties.sample, nil].sample, # Some inquiries without specific property
    inquiry_type: inquiry_types.sample,
    name: users.sample.full_name,
    email: users.sample.email,
    phone: users.sample.phone,
    message: 'Здравствуйте! Интересует данный объект недвижимости. Можно ли договориться о просмотре?',
    status: inquiry_statuses.sample,
    created_at: rand(30.days.ago..Time.current)
  )
  inquiries << inquiry
  print '.'
end

puts "\n✅ Created #{inquiries.count} inquiries"

# ==========================================
# Create Favorites
# ==========================================
puts '❤️  Creating favorites...'

favorites = []
users.each do |user|
  rand(2..8).times do
    favorite = Favorite.create!(
      user: user,
      property: properties.sample
    )
    favorites << favorite
  rescue ActiveRecord::RecordNotUnique
    # Skip duplicates
    next
  end
end

puts "✅ Created #{favorites.count} favorites"

# ==========================================
# Create Reviews
# ==========================================
puts '⭐ Creating reviews...'

reviews = []
20.times do
  review = Review.create!(
    user: users.sample,
    property: properties.sample,
    rating: rand(3..5),
    comment: [
      'Отличный объект! Всё соответствует описанию.',
      'Хорошее расположение, удобная транспортная доступность.',
      'Квартира в хорошем состоянии, рекомендую!',
      'Приятное общение с менеджером, быстро организовали показ.',
      'Всё понравилось, спасибо за помощь в подборе!'
    ].sample,
    status: 'approved',
    created_at: rand(60.days.ago..Time.current)
  )
  reviews << review
  print '.'
end

puts "\n✅ Created #{reviews.count} reviews"

# ==========================================
# Create Saved Searches
# ==========================================
puts '🔍 Creating saved searches...'

saved_searches = []
users.each do |user|
  rand(1..3).times do
    saved_search = SavedSearch.create!(
      user: user,
      name: ['Квартира в центре', '2-комнатная до 10 млн', 'Дом в пригороде', 'Коммерческая недвижимость'].sample,
      criteria: {
        property_type: property_types.sample,
        deal_type: deal_types.sample,
        min_price: 3_000_000,
        max_price: 15_000_000,
        min_area: 40,
        max_area: 100,
        min_rooms: 1,
        district: districts.sample
      },
      notify_on_new: [true, false].sample
    )
    saved_searches << saved_search
  end
end

puts "✅ Created #{saved_searches.count} saved searches"

# ==========================================
# Create Property Views
# ==========================================
puts '👁️  Creating property views...'

property_views = []
users.each do |user|
  rand(5..15).times do
    property_view = PropertyView.create!(
      user: user,
      property: properties.sample,
      created_at: rand(30.days.ago..Time.current)
    )
    property_views << property_view
  rescue ActiveRecord::RecordNotUnique
    # Skip duplicates for same user-property pair on same day
    next
  end
end

puts "✅ Created #{property_views.count} property views"

# ==========================================
# Update property counters
# ==========================================
puts '🔢 Updating counters...'

Property.find_each do |property|
  property.update_columns(
    favorites_count: property.favorites.count,
    inquiries_count: property.inquiries.count
  )
end

puts '✅ Counters updated'

# ==========================================
# Summary
# ==========================================
puts "\n" + '=' * 50
puts '🎉 Database seeding completed!'
puts '=' * 50
puts "👤 Users: #{User.count}"
puts "   - Admin: 1 (admin@viktory-realty.ru / password123)"
puts "   - Manager: 1 (manager@viktory-realty.ru / password123)"
puts "   - Regular users: #{User.where(role: 'user').count}"
puts "🏠 Properties: #{Property.count}"
puts "   - For sale: #{Property.where(deal_type: 'sale').count}"
puts "   - For rent: #{Property.where(deal_type: 'rent').count}"
puts "   - Active: #{Property.where(status: 'active').count}"
puts "📝 Inquiries: #{Inquiry.count}"
puts "❤️  Favorites: #{Favorite.count}"
puts "⭐ Reviews: #{Review.count}"
puts "🔍 Saved Searches: #{SavedSearch.count}"
puts "👁️  Property Views: #{PropertyView.count}"
puts '=' * 50
puts "\n💡 You can now login with:"
puts "   Email: admin@viktory-realty.ru"
puts "   Password: password123"
puts "\n🚀 Start the server with: rails server"
puts '=' * 50
