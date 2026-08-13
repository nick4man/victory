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
  role: 'agent',
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
    phone: "+7 (999) #{100 + i}-00-0#{i}",
    role: 'client',
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

# Справочник типов — это belongs_to, а не строковая колонка. Slug'и должны
# совпадать с продовыми (flat/room/house/land/commerce/garage), иначе сиды
# разъедутся с маппером Topnlab и с фильтрами каталога.
# На чистой базе справочника может не быть — создаём недостающее.
[
  { slug: 'flat',     name: 'Квартиры'          },
  { slug: 'room',     name: 'Комнаты'           },
  { slug: 'house',    name: 'Дома'              },
  { slug: 'land',     name: 'Земельные участки' },
  { slug: 'commerce', name: 'Коммерция'         },
  { slug: 'garage',   name: 'Гаражи'            }
].each do |attrs|
  PropertyType.find_or_create_by!(slug: attrs[:slug]) { |t| t.name = attrs[:name] }
end

property_type_records = PropertyType.order(:id).to_a
# Строковые slug'и держим отдельно: они пригодятся, когда починят SavedSearch (см. ниже).
property_types = property_type_records.map(&:slug)

deal_types = %w[sale rent]
# Значения enum'ов, а не выдуманные строки: condition — integer-enum
# (needs_repair/normal/renovated/euro/designer), status — тоже.
conditions = %w[needs_repair normal renovated euro designer]
statuses = %w[active active active pending] # больше активных
# Объект обязан принадлежать пользователю (belongs_to :user без optional).
listing_owners = [admin, manager]

# Property делает `after_validation :geocode` на каждом изменении адреса, то есть
# сиды ходили во внешний геокодер 50 раз подряд и падали целиком, если сети нет
# (в контейнере это норма). Для выдуманных адресов это бессмысленно.
#
# Пустой стаб, а не фиксированные координаты: geocode при пустом ответе ничего
# не присваивает, и случайные latitude/longitude ниже остаются как есть — иначе
# все 50 объектов легли бы в одну точку на карте.
Geocoder.configure(lookup: :test)
Geocoder::Lookup::Test.set_default_stub([])

properties = []

50.times do |i|
  type = property_type_records.sample
  deal_type = deal_types.sample
  # В сотках — так их считают в объявлениях. В БД колонка land_area_m2,
  # в квадратных метрах (в проде 21.4 сотки лежат как 2140.00), поэтому
  # при записи умножаем на 100.
  land_sotki = nil

  # Характеристики зависят от типа. Ветки — по slug'ам справочника.
  case type.slug
  when 'flat'
    area = rand(30..150)
    rooms = [1, 1, 2, 2, 2, 3, 3, 3, 4, 5].sample
    floor = rand(1..25)
    total_floors = rand(floor..25)
    price = deal_type == 'sale' ? area * rand(150_000..350_000) : area * rand(800..2000)

  when 'room'
    area = rand(9..25)
    rooms = 1
    floor = rand(1..12)
    total_floors = rand(floor..16)
    price = deal_type == 'sale' ? area * rand(80_000..160_000) : area * rand(400..900)

  when 'house'
    area = rand(80..400)
    rooms = rand(3..8)
    floor = 1
    total_floors = rand(1..3)
    land_sotki = rand(3..25)
    price = deal_type == 'sale' ? area * rand(120_000..250_000) : area * rand(600..1500)

  when 'land'
    land_sotki = rand(6..50)
    area = land_sotki * 100 # площадь участка в м², как в каталоге
    rooms = nil
    floor = nil
    total_floors = nil
    price = deal_type == 'sale' ? land_sotki * rand(100_000..500_000) : land_sotki * rand(5000..15_000)

  when 'commerce'
    area = rand(50..500)
    rooms = nil
    floor = rand(1..10)
    total_floors = rand(floor..20)
    price = deal_type == 'sale' ? area * rand(250_000..600_000) : area * rand(1500..5000)

  when 'garage'
    area = rand(12..40)
    rooms = nil
    floor = nil
    total_floors = nil
    price = deal_type == 'sale' ? area * rand(30_000..90_000) : area * rand(200..600)
  end

  district = districts.sample
  metro = metro_stations.sample
  condition = conditions.sample

  # `title` валидируется на минимум 10 символов — название типа плюс площадь
  # и район дают запас в любом случае.
  property = Property.create!(
    user: listing_owners.sample,
    property_type: type,
    title: "#{type.name.singularize} #{area} м² в районе #{district}",
    description: "#{type.name.singularize} в районе #{district}. " \
                 "#{deal_type == 'sale' ? 'Продаётся' : 'Сдаётся'}, состояние — #{condition}. " \
                 "#{land_sotki ? "Участок #{land_sotki} соток. " : ''}" \
                 'Развитая инфраструктура, удобная транспортная доступность.',
    deal_type: deal_type,
    price: price,
    area: area,
    land_area_m2: land_sotki && land_sotki * 100,
    rooms: rooms,
    floor: floor,
    total_floors: total_floors,
    address: "Москва, #{district} район, ул. #{['Ленина', 'Пушкина', 'Чехова', 'Горького', 'Тверская'][i % 5]}, д. #{rand(1..100)}",
    district: district,
    metro_station: metro,
    metro_distance: rand(3..20),
    condition: condition,
    status: statuses.sample,
    views_count: rand(0..500),
    latitude: 55.751244 + rand(-0.3..0.3),
    longitude: 37.618423 + rand(-0.3..0.3)
  )

  properties << property
  print '.'
end

puts "\n✅ Created #{properties.count} properties"

# ==========================================
# Create Inquiries
# ==========================================
puts '📝 Creating inquiries...'

# Значения из enum'ов Inquiry, а не выдуманные: `property_selection` и
# `pending` в схеме не существуют и роняли create! с ArgumentError.
inquiry_types = %w[viewing callback consultation mortgage evaluation quick_inquiry]
inquiry_statuses = %w[new contacted in_progress scheduled completed]

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
    # find_or_create_by вместо create! + rescue: дубль теперь ловится
    # валидацией модели (RecordInvalid), а не уникальным индексом
    # (RecordNotUnique), и прежний rescue его не перехватывал.
    favorites << Favorite.find_or_create_by!(user: user, property: properties.sample)
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
    # Колонка называется body, не comment (см. комментарий у валидации в модели).
    # review_type и source не задаём — у обоих есть дефолты в схеме.
    body: [
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
# ⚠️ SavedSearch сейчас создать НЕВОЗМОЖНО — баг в самой модели, не в сидах.
#
# app/models/saved_search.rb:14 валидирует presence у `search_params`, а такой
# колонки в схеме нет: есть `filters` (jsonb NOT NULL default '{}'). Атрибут
# существует только как побочный эффект `serialize :search_params` (строка 29)
# и всегда равен nil, поэтому presence-валидация не проходит никогда.
#
# Проверено: SavedSearch.column_names → ["filters"], respond_to?(:search_params)
# → true, значение → nil. В проде записей 0 — согласуется с тем, что фича не
# работала ни разу. При этом на модель ссылаются два контроллера
# (dashboard/saved_searches_controller, api/v1/saved_searches_controller).
#
# Чинить надо в модели (перевести на `filters` либо завести alias), и это
# решение вне объёма правки сидов — оно меняет поведение фичи. Пока блок
# пропускается явно, а не тихо удалён, чтобы баг не потерялся.
puts '🔍 Saved searches: пропущено (SavedSearch#search_params не связан со схемой — см. комментарий)'
saved_searches = []

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
puts "   - Regular users: #{User.where(role: 'client').count}"
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
