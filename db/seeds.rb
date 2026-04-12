# frozen_string_literal: true

puts 'Начинаю наполнение базы данных...'

# Очищаем данные в development
if Rails.env.development?
  puts 'Очищаю существующие данные...'
  PropertyView.delete_all
  Favorite.delete_all
  SavedSearch.delete_all
  Inquiry.delete_all
  Property.unscoped.delete_all
  User.unscoped.delete_all
  PropertyType.delete_all
  puts 'Данные очищены.'
end

# =============================================================================
# Типы недвижимости
# =============================================================================
puts 'Создаю типы недвижимости...'

property_types = {
  'apartment' => 'Квартира',
  'house'     => 'Дом',
  'land'      => 'Земельный участок',
  'commercial' => 'Коммерческая',
  'garage'    => 'Гараж',
  'room'      => 'Комната'
}

pt_records = property_types.map do |key, name|
  PropertyType.create!(name: name, slug: key)
end
puts "Создано #{pt_records.count} типов недвижимости."

# =============================================================================
# Пользователи
# =============================================================================
puts 'Создаю администратора...'
admin = User.create!(
  email: 'admin@viktory-realty.ru',
  password: 'Password123!',
  password_confirmation: 'Password123!',
  first_name: 'Администратор',
  last_name: 'Виктори',
  phone: '79991234567',
  role: 'admin',
  confirmed_at: Time.current
)
puts "Администратор создан: #{admin.email}"

puts 'Создаю агента...'
agent = User.create!(
  email: 'agent@viktory-realty.ru',
  password: 'Password123!',
  password_confirmation: 'Password123!',
  first_name: 'Иван',
  last_name: 'Петров',
  phone: '79992345678',
  role: 'agent',
  confirmed_at: Time.current
)
puts "Агент создан: #{agent.email}"

puts 'Создаю клиентов...'
client_data = [
  { first_name: 'Александр', last_name: 'Смирнов',   phone: '79993001001' },
  { first_name: 'Елена',     last_name: 'Иванова',    phone: '79993002002' },
  { first_name: 'Михаил',    last_name: 'Сидоров',    phone: '79993003003' },
  { first_name: 'Ольга',     last_name: 'Козлова',    phone: '79993004004' },
  { first_name: 'Дмитрий',   last_name: 'Новиков',    phone: '79993005005' }
]

clients = client_data.each_with_index.map do |data, i|
  User.create!(
    email: "client#{i + 1}@example.com",
    password: 'Password123!',
    password_confirmation: 'Password123!',
    first_name: data[:first_name],
    last_name:  data[:last_name],
    phone:      data[:phone],
    role:       'client',
    confirmed_at: Time.current
  )
end
puts "Создано #{clients.count} клиентов."

# =============================================================================
# Объекты недвижимости
# =============================================================================
puts 'Создаю объекты недвижимости...'

districts = ['Центральный', 'Арбат', 'Тверской', 'Замоскворечье', 'Хамовники',
             'Сокольники', 'Преображенское', 'Лефортово', 'Бутово', 'Митино']

metro_stations = ['Арбатская', 'Тверская', 'Таганская', 'Сокольники',
                  'Академическая', 'Проспект Мира', 'Кутузовская', 'Выставочная']

building_types = ['монолит', 'кирпич', 'панель', 'сталинка', 'блочный']
conditions = %w[normal renovated euro designer]
deal_types = %w[sale rent]

apartment_type = PropertyType.find_by(slug: 'apartment')
house_type     = PropertyType.find_by(slug: 'house')
commercial_type = PropertyType.find_by(slug: 'commercial')

properties_data = [
  { title: '1-комнатная квартира у метро Арбатская', rooms: 1, area: 38, price: 9_500_000,   deal_type: 'sale', district: 'Арбат', metro_station: 'Арбатская', metro_distance: 300, floor: 5, total_floors: 12 },
  { title: '2-комнатная квартира в Хамовниках',       rooms: 2, area: 65, price: 18_000_000,  deal_type: 'sale', district: 'Хамовники', metro_station: 'Кутузовская', metro_distance: 600, floor: 8, total_floors: 16 },
  { title: '3-комнатная квартира в центре Москвы',    rooms: 3, area: 95, price: 32_000_000,  deal_type: 'sale', district: 'Центральный', metro_station: 'Тверская', metro_distance: 400, floor: 4, total_floors: 9 },
  { title: 'Студия у парка Сокольники',               rooms: 0, area: 28, price: 7_200_000,   deal_type: 'sale', district: 'Сокольники', metro_station: 'Сокольники', metro_distance: 500, floor: 2, total_floors: 14 },
  { title: '4-комнатная квартира в Замоскворечье',    rooms: 4, area: 120, price: 45_000_000, deal_type: 'sale', district: 'Замоскворечье', metro_station: 'Таганская', metro_distance: 700, floor: 7, total_floors: 10 },
  { title: '1-комнатная квартира в аренду',           rooms: 1, area: 42, price: 60_000,      deal_type: 'rent', district: 'Сокольники', metro_station: 'Сокольники', metro_distance: 400, floor: 3, total_floors: 17 },
  { title: '2-комнатная квартира в аренду на Арбате', rooms: 2, area: 58, price: 95_000,      deal_type: 'rent', district: 'Арбат', metro_station: 'Арбатская', metro_distance: 200, floor: 6, total_floors: 8 },
  { title: '3-комнатная квартира в аренду в Митино',  rooms: 3, area: 80, price: 110_000,     deal_type: 'rent', district: 'Митино', metro_station: 'Выставочная', metro_distance: 900, floor: 12, total_floors: 20 },
  { title: 'Загородный дом в Подмосковье 180 м²',     rooms: 5, area: 180, price: 25_000_000, deal_type: 'sale', district: 'Бутово', metro_station: nil, metro_distance: nil, floor: 1, total_floors: 2 },
  { title: 'Офис в бизнес-центре на Тверской',        rooms: nil, area: 75, price: 250_000,   deal_type: 'rent', district: 'Тверской', metro_station: 'Тверская', metro_distance: 100, floor: 3, total_floors: 8 }
]

properties = properties_data.map do |data|
  prop_type = data[:title].include?('дом') ? house_type : (data[:title].include?('Офис') ? commercial_type : apartment_type)

  Property.create!(
    user:           agent,
    property_type:  prop_type,
    title:          data[:title],
    description:    "Отличный объект в #{data[:district]}. Удобное расположение, развитая инфраструктура. Собственник. Документы готовы.",
    deal_type:      data[:deal_type],
    status:         'active',
    published_at:   rand(1..60).days.ago,
    price:          data[:price],
    area:           data[:area],
    rooms:          data[:rooms],
    floor:          data[:floor],
    total_floors:   data[:total_floors],
    address:        "Москва, #{data[:district]}, #{%w[ул. пр. пер.].sample} #{%w[Ленина Пушкина Гагарина Садовая Лесная].sample}, д. #{rand(1..150)}",
    district:       data[:district],
    metro_station:  data[:metro_station],
    metro_distance: data[:metro_distance],
    condition:      conditions.sample,
    building_type:  building_types.sample,
    building_year:  rand(1970..2023),
    has_balcony:    [true, false].sample,
    has_parking:    [true, false].sample,
    has_elevator:   data[:total_floors] > 5,
    mortgage_allowed: true,
    is_featured:    data[:deal_type] == 'sale' && data[:price] > 15_000_000
  )
end
puts "Создано #{properties.count} объектов недвижимости."

# =============================================================================
# Избранное и просмотры
# =============================================================================
puts 'Создаю избранное и просмотры...'
clients.each do |client|
  properties.sample(rand(2..4)).each do |property|
    Favorite.find_or_create_by!(user: client, property: property)
    PropertyView.find_or_create_by!(
      user: client,
      property: property
    ) do |view|
      view.viewed_at = rand(1..30).days.ago if view.respond_to?(:viewed_at=)
      view.ip_address = "192.168.1.#{rand(1..254)}"
    end
  end
end
puts 'Избранное и просмотры созданы.'

# =============================================================================
# Заявки
# =============================================================================
puts 'Создаю заявки...'
inquiry_data = [
  { type: 'viewing',      name: 'Сергей Волков',    phone: '79995001001', email: 'volkov@example.com' },
  { type: 'consultation', name: 'Анна Белова',       phone: '79995002002', email: 'belova@example.com' },
  { type: 'callback',     name: 'Николай Морозов',   phone: '79995003003', email: nil },
  { type: 'evaluation',   name: 'Татьяна Федорова',  phone: '79995004004', email: 'fedorova@example.com' },
  { type: 'quick_inquiry', name: 'Роман Алексеев',   phone: '79995005005', email: nil }
]

inquiry_data.each do |data|
  Inquiry.create!(
    inquiry_type: data[:type],
    name:         data[:name],
    phone:        data[:phone],
    email:        data[:email],
    property:     properties.sample,
    message:      'Интересует данный объект. Прошу связаться для уточнения деталей.',
    source:       'web',
    status:       'new'
  )
end
puts "Создано #{Inquiry.count} заявок."

# =============================================================================
# Сохранённые поиски
# =============================================================================
puts 'Создаю сохранённые поиски...'
clients.first(3).each do |client|
  SavedSearch.create!(
    user:       client,
    name:       "#{%w[Квартира Дом Студия].sample} в #{districts.sample}",
    filters:    { deal_type: 'sale', district: districts.sample, max_price: rand(10..30) * 1_000_000 },
    active:     true
  )
end
puts 'Сохранённые поиски созданы.'

puts ''
puts '=' * 50
puts 'База данных заполнена!'
puts '=' * 50
puts "Администратор: admin@viktory-realty.ru / Password123!"
puts "Агент:         agent@viktory-realty.ru / Password123!"
puts "Клиент:        client1@example.com / Password123!"
puts "Объектов:      #{Property.count}"
puts "Заявок:        #{Inquiry.count}"
User.create!(email: 'admin@example.com', password: 'password', password_confirmation: 'password') if Rails.env.development?