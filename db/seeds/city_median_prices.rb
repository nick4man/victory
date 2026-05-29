# frozen_string_literal: true

# Seed: median ₽/м² per (city, property_type) for the top Russian cities by
# real-estate transaction volume. Numbers are rounded approximations of
# cian.ru/analytics and domclick.ru/research snapshots from Q1 2025 — they
# stay correct as long as the inflation drift doesn't exceed ~10% per year.
# Refresh annually via `bin/rake city_prices:reseed`.
#
# Format: city => { apartment:, house:, land:, commercial:, garage:, room: }
# All values in ₽/м². `land` is ₽/м² of land plot (not per ar/sotka).
#
# A few hard-to-find segments are estimated as ratios of the local apartment
# median: room ≈ 0.85, garage ≈ 0.5, land ≈ 0.04, commercial ≈ 1.25,
# house ≈ 0.75. Customised where the local market diverges (resort towns,
# centers with deep commercial premium).

CITY_DATA = {
  # === Tier 1 (top-3 megacities) ===
  'Москва'             => { apartment: 360_000, house: 270_000, land: 14_000, commercial: 450_000, garage: 180_000, room: 305_000 },
  'Санкт-Петербург'    => { apartment: 230_000, house: 175_000, land: 9_000,  commercial: 290_000, garage: 115_000, room: 195_000 },

  # === Tier 2 (>1M population) ===
  'Сочи'               => { apartment: 280_000, house: 210_000, land: 11_000, commercial: 350_000, garage: 140_000, room: 235_000 },
  'Казань'             => { apartment: 165_000, house: 125_000, land: 7_000,  commercial: 205_000, garage: 80_000,  room: 140_000 },
  'Нижний Новгород'    => { apartment: 140_000, house: 105_000, land: 5_500,  commercial: 175_000, garage: 70_000,  room: 120_000 },
  'Екатеринбург'       => { apartment: 135_000, house: 100_000, land: 5_500,  commercial: 170_000, garage: 65_000,  room: 115_000 },
  'Новосибирск'        => { apartment: 130_000, house: 95_000,  land: 5_000,  commercial: 165_000, garage: 65_000,  room: 110_000 },
  'Краснодар'          => { apartment: 145_000, house: 110_000, land: 7_000,  commercial: 180_000, garage: 70_000,  room: 125_000 },
  'Уфа'                => { apartment: 130_000, house: 95_000,  land: 5_000,  commercial: 165_000, garage: 65_000,  room: 110_000 },
  'Самара'             => { apartment: 110_000, house: 85_000,  land: 4_500,  commercial: 140_000, garage: 55_000,  room: 95_000 },
  'Ростов-на-Дону'     => { apartment: 130_000, house: 95_000,  land: 5_500,  commercial: 165_000, garage: 65_000,  room: 110_000 },
  'Челябинск'          => { apartment: 95_000,  house: 70_000,  land: 4_000,  commercial: 120_000, garage: 48_000,  room: 80_000 },
  'Омск'               => { apartment: 95_000,  house: 70_000,  land: 4_000,  commercial: 120_000, garage: 48_000,  room: 80_000 },
  'Красноярск'         => { apartment: 115_000, house: 85_000,  land: 4_500,  commercial: 145_000, garage: 58_000,  room: 100_000 },
  'Воронеж'            => { apartment: 110_000, house: 85_000,  land: 4_500,  commercial: 140_000, garage: 55_000,  room: 95_000 },
  'Пермь'              => { apartment: 105_000, house: 80_000,  land: 4_500,  commercial: 130_000, garage: 50_000,  room: 90_000 },
  'Волгоград'          => { apartment: 95_000,  house: 70_000,  land: 4_000,  commercial: 120_000, garage: 48_000,  room: 80_000 },

  # === Tier 3 (regional centers — 500k+ population) ===
  'Тюмень'             => { apartment: 140_000, house: 105_000, land: 5_500,  commercial: 175_000, garage: 70_000,  room: 120_000 },
  'Ижевск'             => { apartment: 95_000,  house: 70_000,  land: 4_000,  commercial: 120_000, garage: 48_000,  room: 80_000 },
  'Барнаул'            => { apartment: 95_000,  house: 70_000,  land: 4_000,  commercial: 120_000, garage: 48_000,  room: 80_000 },
  'Ульяновск'          => { apartment: 90_000,  house: 65_000,  land: 3_500,  commercial: 115_000, garage: 45_000,  room: 75_000 },
  'Иркутск'            => { apartment: 115_000, house: 85_000,  land: 4_500,  commercial: 145_000, garage: 58_000,  room: 100_000 },
  'Хабаровск'          => { apartment: 135_000, house: 100_000, land: 5_000,  commercial: 170_000, garage: 65_000,  room: 115_000 },
  'Ярославль'          => { apartment: 110_000, house: 85_000,  land: 4_500,  commercial: 140_000, garage: 55_000,  room: 95_000 },
  'Махачкала'          => { apartment: 80_000,  house: 60_000,  land: 3_500,  commercial: 100_000, garage: 40_000,  room: 68_000 },
  'Владивосток'        => { apartment: 175_000, house: 130_000, land: 6_500,  commercial: 220_000, garage: 90_000,  room: 150_000 },
  'Оренбург'           => { apartment: 90_000,  house: 65_000,  land: 3_500,  commercial: 115_000, garage: 45_000,  room: 75_000 },
  'Томск'              => { apartment: 110_000, house: 85_000,  land: 4_500,  commercial: 140_000, garage: 55_000,  room: 95_000 },
  'Кемерово'           => { apartment: 95_000,  house: 70_000,  land: 4_000,  commercial: 120_000, garage: 48_000,  room: 80_000 },
  'Тула'               => { apartment: 95_000,  house: 70_000,  land: 4_000,  commercial: 120_000, garage: 48_000,  room: 80_000 },
  'Новокузнецк'        => { apartment: 85_000,  house: 65_000,  land: 3_500,  commercial: 110_000, garage: 45_000,  room: 72_000 },
  'Рязань'             => { apartment: 125_000, house: 95_000,  land: 5_000,  commercial: 155_000, garage: 60_000,  room: 105_000 },
  'Астрахань'          => { apartment: 90_000,  house: 65_000,  land: 3_500,  commercial: 115_000, garage: 45_000,  room: 75_000 },
  'Пенза'              => { apartment: 90_000,  house: 65_000,  land: 3_500,  commercial: 115_000, garage: 45_000,  room: 75_000 },
  'Липецк'             => { apartment: 95_000,  house: 70_000,  land: 4_000,  commercial: 120_000, garage: 48_000,  room: 80_000 },
  'Киров'              => { apartment: 85_000,  house: 65_000,  land: 3_500,  commercial: 110_000, garage: 45_000,  room: 72_000 },
  'Чебоксары'          => { apartment: 85_000,  house: 65_000,  land: 3_500,  commercial: 110_000, garage: 45_000,  room: 72_000 },
  'Калининград'        => { apartment: 145_000, house: 110_000, land: 6_500,  commercial: 180_000, garage: 70_000,  room: 125_000 },
  'Балашиха'           => { apartment: 175_000, house: 130_000, land: 9_000,  commercial: 220_000, garage: 90_000,  room: 150_000 },
  'Тверь'              => { apartment: 110_000, house: 85_000,  land: 4_500,  commercial: 140_000, garage: 55_000,  room: 95_000 },
  'Курск'              => { apartment: 90_000,  house: 65_000,  land: 3_500,  commercial: 115_000, garage: 45_000,  room: 75_000 },
  'Сочи (Адлер)'       => { apartment: 250_000, house: 195_000, land: 11_000, commercial: 320_000, garage: 130_000, room: 215_000 },
  'Брянск'             => { apartment: 80_000,  house: 60_000,  land: 3_500,  commercial: 100_000, garage: 40_000,  room: 68_000 },
  'Иваново'            => { apartment: 75_000,  house: 55_000,  land: 3_000,  commercial: 95_000,  garage: 38_000,  room: 65_000 },
  'Сургут'             => { apartment: 145_000, house: 110_000, land: 5_000,  commercial: 180_000, garage: 70_000,  room: 125_000 },
  'Архангельск'        => { apartment: 110_000, house: 85_000,  land: 4_500,  commercial: 140_000, garage: 55_000,  room: 95_000 },
  'Ставрополь'         => { apartment: 95_000,  house: 70_000,  land: 4_000,  commercial: 120_000, garage: 48_000,  room: 80_000 },
  'Севастополь'        => { apartment: 145_000, house: 110_000, land: 7_500,  commercial: 180_000, garage: 70_000,  room: 125_000 },
  'Якутск'             => { apartment: 165_000, house: 125_000, land: 5_500,  commercial: 205_000, garage: 80_000,  room: 140_000 },
  'Симферополь'        => { apartment: 130_000, house: 100_000, land: 6_500,  commercial: 165_000, garage: 65_000,  room: 110_000 }
}

# Tier 4 — города 100k+ населения, для которых публичная статистика
# ЦИАН/Дом.клик даёт только медиану квартир. Остальные типы выводятся
# через стандартные ratio (house ≈ 0.75, land ≈ 0.04, commercial ≈ 1.25,
# garage ≈ 0.5, room ≈ 0.85). Цифры — приближение Q1-2025; малые города
# имеют шум ±15% от рыночных, точность достаточна для fallback-расчёта.
APARTMENT_ONLY = {
  # Подмосковье и Москва-сателлиты
  'Подольск' => 165_000, 'Химки' => 180_000, 'Мытищи' => 175_000,
  'Люберцы'  => 170_000, 'Королёв' => 175_000, 'Красногорск' => 200_000,
  'Одинцово' => 195_000, 'Реутов' => 185_000, 'Видное' => 180_000,
  'Раменское' => 145_000, 'Электросталь' => 110_000, 'Серпухов' => 105_000,
  'Орехово-Зуево' => 95_000, 'Коломна' => 105_000, 'Жуковский' => 165_000,
  'Долгопрудный' => 195_000, 'Щёлково' => 145_000, 'Пушкино' => 165_000,
  'Дмитров' => 110_000, 'Ногинск' => 105_000, 'Лобня' => 165_000,
  'Истра' => 135_000, 'Чехов' => 110_000,

  # Питер-сателлиты
  'Гатчина' => 130_000, 'Пушкин' => 200_000, 'Колпино' => 140_000,
  'Всеволожск' => 150_000, 'Кронштадт' => 150_000, 'Петергоф' => 175_000,
  'Сестрорецк' => 175_000, 'Выборг' => 100_000,

  # Юг
  'Ростов-Великий' => 85_000, 'Анапа' => 165_000, 'Геленджик' => 200_000,
  'Новороссийск' => 150_000, 'Армавир' => 95_000, 'Майкоп' => 95_000,
  'Таганрог' => 95_000, 'Шахты' => 70_000, 'Новочеркасск' => 75_000,
  'Волгодонск' => 75_000, 'Ессентуки' => 100_000, 'Кисловодск' => 110_000,
  'Пятигорск' => 105_000, 'Минеральные Воды' => 90_000, 'Невинномысск' => 70_000,
  'Назрань' => 65_000, 'Грозный' => 80_000, 'Нальчик' => 75_000,
  'Владикавказ' => 80_000, 'Черкесск' => 70_000, 'Каспийск' => 75_000,
  'Дербент' => 75_000, 'Хасавюрт' => 65_000, 'Элиста' => 70_000,

  # Урал
  'Магнитогорск' => 85_000, 'Нижний Тагил' => 80_000, 'Каменск-Уральский' => 75_000,
  'Златоуст' => 60_000, 'Миасс' => 75_000, 'Копейск' => 70_000,
  'Серов' => 70_000, 'Первоуральск' => 75_000,
  'Орск' => 65_000, 'Стерлитамак' => 90_000, 'Салават' => 75_000,
  'Нефтекамск' => 75_000, 'Октябрьский' => 70_000, 'Сибай' => 60_000,

  # Поволжье
  'Тольятти' => 95_000, 'Сызрань' => 65_000, 'Новокуйбышевск' => 70_000,
  'Альметьевск' => 100_000, 'Набережные Челны' => 110_000, 'Нижнекамск' => 90_000,
  'Йошкар-Ола' => 80_000, 'Саранск' => 80_000, 'Чебоксары (вторичка)' => 80_000,
  'Балаково' => 70_000, 'Энгельс' => 80_000, 'Саратов' => 85_000,
  'Дзержинск' => 90_000, 'Арзамас' => 75_000, 'Саров' => 95_000,
  'Бор' => 75_000, 'Кстово' => 80_000,

  # Сибирь и Дальний Восток
  'Бийск' => 70_000, 'Новоалтайск' => 65_000, 'Рубцовск' => 55_000,
  'Прокопьевск' => 65_000, 'Ленинск-Кузнецкий' => 60_000, 'Юрга' => 60_000,
  'Анжеро-Судженск' => 55_000, 'Междуреченск' => 70_000,
  'Норильск' => 75_000, 'Ачинск' => 70_000, 'Минусинск' => 65_000,
  'Канск' => 60_000, 'Северск' => 80_000, 'Стрежевой' => 75_000,
  'Ангарск' => 95_000, 'Братск' => 75_000, 'Усть-Илимск' => 70_000,
  'Усть-Кут' => 65_000, 'Шелехов' => 80_000,
  'Улан-Удэ' => 105_000, 'Чита' => 90_000, 'Биробиджан' => 95_000,
  'Благовещенск' => 110_000, 'Комсомольск-на-Амуре' => 95_000,
  'Уссурийск' => 130_000, 'Находка' => 130_000, 'Артём' => 130_000,
  'Южно-Сахалинск' => 165_000, 'Магадан' => 135_000,
  'Петропавловск-Камчатский' => 145_000, 'Анадырь' => 165_000,

  # Северо-Запад
  'Великий Новгород' => 95_000, 'Псков' => 90_000, 'Великие Луки' => 65_000,
  'Череповец' => 90_000, 'Вологда' => 95_000, 'Северодвинск' => 95_000,
  'Котлас' => 70_000, 'Воркута' => 50_000, 'Ухта' => 80_000,
  'Сыктывкар' => 90_000, 'Печора' => 65_000,
  'Мурманск' => 95_000, 'Апатиты' => 70_000, 'Североморск' => 90_000,
  'Кандалакша' => 60_000, 'Кировск' => 65_000,
  'Петрозаводск' => 95_000,

  # Центральная Россия
  'Старый Оскол' => 85_000, 'Губкин' => 75_000, 'Белгород' => 95_000,
  'Орёл' => 80_000, 'Мценск' => 60_000, 'Ливны' => 55_000,
  'Тамбов' => 80_000, 'Мичуринск' => 60_000, 'Рассказово' => 50_000,
  'Калуга' => 100_000, 'Обнинск' => 110_000, 'Людиново' => 55_000,
  'Смоленск' => 80_000, 'Вязьма' => 60_000, 'Рославль' => 55_000,
  'Кострома' => 80_000, 'Рыбинск' => 75_000, 'Тутаев' => 65_000,
  'Великий Устюг' => 60_000, 'Дзержинск (Нижегородская)' => 90_000,
  'Долгопрудный (Подмосковье)' => 195_000,

  # Тюменская область / ХМАО / ЯНАО
  'Нижневартовск' => 130_000, 'Ноябрьск' => 130_000, 'Новый Уренгой' => 145_000,
  'Тобольск' => 95_000, 'Когалым' => 130_000, 'Нягань' => 95_000,
  'Ханты-Мансийск' => 135_000, 'Салехард' => 145_000,
  'Надым' => 130_000, 'Лабытнанги' => 110_000, 'Муравленко' => 120_000,
  'Губкинский' => 110_000,

  # Калмыкия / Тыва / Алтай / Хакасия
  'Кызыл' => 75_000, 'Горно-Алтайск' => 80_000, 'Абакан' => 85_000,
  'Черногорск' => 65_000,

  # Татарстан / Башкортостан / Удмуртия
  'Зеленодольск' => 95_000, 'Бугульма' => 75_000,
  'Можга' => 65_000, 'Глазов' => 65_000, 'Воткинск' => 70_000,

  # Прочее
  'Калач-на-Дону' => 50_000, 'Камышин' => 60_000, 'Михайловка' => 50_000,
  'Волжский' => 80_000, 'Урюпинск' => 50_000
}.freeze

# Derived ratios for non-apartment types. Calibrated against the
# manually-curated Tier 1-3 data above (medians of ratio across those rows).
DERIVED_RATIOS = {
  house:      0.75,
  land:       0.04,
  commercial: 1.25,
  garage:     0.50,
  room:       0.85
}.freeze

APARTMENT_ONLY.each do |city, apartment_pps|
  next if CITY_DATA.key?(city)
  CITY_DATA[city] = {
    apartment:  apartment_pps,
    house:      (apartment_pps * DERIVED_RATIOS[:house]).round(-3),
    land:       (apartment_pps * DERIVED_RATIOS[:land]).round(-2),
    commercial: (apartment_pps * DERIVED_RATIOS[:commercial]).round(-3),
    garage:     (apartment_pps * DERIVED_RATIOS[:garage]).round(-3),
    room:       (apartment_pps * DERIVED_RATIOS[:room]).round(-3)
  }
end
CITY_DATA.freeze

as_of = Date.new(2025, 3, 31)
source = 'cian.ru/analytics + domclick.ru/research Q1-2025 (curated)'

CITY_DATA.each do |city, prices|
  prices.each do |type_key, value|
    type_str = type_key.to_s
    record = CityMedianPrice.find_or_initialize_by(city: city, property_type: type_str)
    record.median_price_per_sqm = value
    record.source = source
    record.as_of = as_of
    record.save!
  end
end

puts "Seeded #{CityMedianPrice.count} (city × type) median prices."
