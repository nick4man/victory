# frozen_string_literal: true

# A2 — стартовый справочник ЖК. Запуск: `rake zhk:seed`.
# НЕ подключён в db/seeds.rb — прод-сиды не должны прогоняться автоматом.
#
# Ревизия 07.09.26. Прошлая редакция (08.08.26) брала названия из
# редакционных партиалов лендингов — маркетинговой прозы — и фактуру не
# заполняла вовсе. Список пересобран: каждая запись подтверждена сайтом
# застройщика плюс минимум одним независимым реестром (ЕРЗ.РФ, ЦИАН,
# Домклик, 2ГИС), ссылки стоят рядом с записью. Добавились ЖК, названные
# в карточках нашего же каталога («Северный», «Маргелов», «Пожарский»,
# «Лето», «Голландия») — это объекты, которые агентство реально продаёт.
#
# Правило прежнее и главное: НЕ додумывать. Поле остаётся nil, когда
# источники расходятся (класс жилья у «Скобелева» и «Легенды», застройщик
# «Метропарка», стадия «Пожарского») или когда факт не найден. Неверная
# фактура на entity-странице хуже отсутствующей — это прямая дорога к
# «недостоверной информации» в Я.Вебмастере. Дозаполняет редактор через
# админку, сверяясь с застройщиком и наш.дом.рф.
#
# `district_slug` — только слаги из `RyazanDistricts::MICRO`. У «Метропарка»
# (Мервино) и «Лета» (Михайловское шоссе) таких микрорайонов в реестре нет,
# поэтому там nil: выдуманный слаг не пройдёт валидацию, а ближайший чужой
# увёл бы ЖК на посадочную соседнего района.
#
# `address_patterns` — ILIKE-подстроки для `Zhk::AttachmentSuggester#by_patterns`,
# сверены с форматом `properties.address` на проде («Рязанская обл., г. Рязань,
# ДП, ул. Льговская, д. 10, кв. 469»). Паттерны на уровне ДОМА, а не улицы:
# «Северный» и «Пожарский» стоят на одной Зубковой, и уличный паттерн
# склеил бы их инвентарь в одну кучу.

# Локальная переменная, не константа: файл прогоняется через `load`, и
# повторный прогон в том же процессе сыпал бы «already initialized constant».
seed_complexes = [
  # edinstvo62.ru/building/83 + erzrf.ru/novostroyki/zhk-skobelev-564336001
  # Класс не ставим: ЕРЗ пишет «стандарт», m2.ru — «комфорт».
  { slug: 'skobelev', name: 'Скобелев', district_slug: 'dashkovo-pesochnya',
    developer: 'Единство', address: 'Рязань, ул. Шереметьевская',
    address_patterns: ['ул. Шереметьевская'],
    built_to: 2022, buildings_count: 4, build_status: :completed },

  # edinstvo62.ru/building/96 + ryazan.cian.ru/zhiloy-kompleks-legenda-kanishcevo-mkr-189029
  # Класс не ставим: ЦИАН — «комфорт», novostroyki.org — «бизнес».
  { slug: 'legenda', name: 'Легенда', district_slug: 'kanishchevo',
    developer: 'Единство', address: 'Рязань, ул. Интернациональная, 20',
    address_patterns: ['ул. Интернациональная, д. 20'],
    built_to: 2023, floors_min: 17, floors_max: 23,
    wall_material: 'монолитно-кирпичный', build_status: :completed },

  # erzrf.ru/novostroyki/zhk-priokskij-park-565601001 + ryazan.cian.ru/zhiloy-kompleks-priokskiy-park-ryazan-38832
  { slug: 'priokskiy-park', name: 'Приокский парк', district_slug: 'priokskiy',
    developer: 'Единство', address: 'Рязань, ул. Октябрьская, 65Б',
    address_patterns: ['ул. Октябрьская, д. 65'],
    built_to: 2026, buildings_count: 2, floors_min: 3, floors_max: 18,
    build_status: :under_construction },

  # edinstvo62.ru/building/81 и /82 + ryazan.etagi.com/zastr/jk/vidnyjj-2378
  # Стадию не ставим: очереди сданы вразнобой, единой даты у источников нет.
  { slug: 'vidnyy', name: 'Видный', district_slug: 'semchino',
    developer: 'Единство', address: 'Рязань, ул. Княжье Поле, 1Б',
    address_patterns: ['ул. Княжье Поле', 'ул. Рыбновская'] },

  # otkritie62.ru (сайт объекта) + edinstvo62.ru/complex/55
  # Единственный класс, который ставим: заявлен самим застройщиком.
  { slug: 'otkrytie', name: 'Открытие', district_slug: 'dashkovo-pesochnya',
    developer: 'Единство', address: 'Рязань, ул. Льговская, 6, 8, 10',
    address_patterns: ['ул. Льговская, д. 6', 'ул. Льговская, д. 8', 'ул. Льговская, д. 10'],
    built_to: 2027, buildings_count: 6, housing_class: :comfort,
    build_status: :under_construction },

  # edinstvo62.ru/building/90 + m2.ru/ryazan/novostroyki/zhk-pozharskii-5539
  # Застройщик по ДДУ — ООО «Атом» (проектная компания), в продаже и на сайте
  # проходит как объект ГК «Единство»; ставим бренд. Стадия расходится:
  # m2 — корпус сдан 2019, 2ГИС — «строящийся».
  { slug: 'pozharskiy', name: 'Пожарский', district_slug: 'dashkovo-pesochnya',
    developer: 'Единство', address: 'Рязань, ул. Зубковой, 27',
    address_patterns: ['ул. Зубковой, д. 27'],
    buildings_count: 2 },

  # sk62.ru/object/jk-severniy-korpus-7 + erzrf.ru/novostroyki/zhk-severnyj-609257001
  { slug: 'severnyy', name: 'Северный', district_slug: 'dashkovo-pesochnya',
    developer: 'Северная компания', address: 'Рязань, ул. Зубковой, 4',
    address_patterns: ['ул. Зубковой, д. 1', 'ул. Зубковой, д. 4'],
    build_status: :under_construction },

  # ryazan.cian.ru/kupit-kvartiru-zhiloy-kompleks-margelov-39596 + egrp.ru (СЗ «Старт»)
  { slug: 'margelov', name: 'Маргелов', district_slug: 'kalnoe',
    developer: 'Единство', address: 'Рязань, ул. Быстрецкая, 10',
    address_patterns: ['ул. Быстрецкая, д. 10'],
    built_to: 2021, floors_max: 27, build_status: :completed },

  # ryazan.cian.ru/zhiloy-kompleks-metropark-ryazan-39262 + ryazan.domclick.ru (Мервино)
  # Застройщика НЕ ставим: ЦИАН — «Северная компания», Домклик — «Капитал-строитель
  # жилья». Район — nil: Мервино в RyazanDistricts::MICRO нет.
  { slug: 'metropark', name: 'Метропарк', district_slug: nil,
    developer: nil, address: 'Рязань, ул. Александра Полина',
    address_patterns: ['ул. Александра Полина', 'ул. Полина'],
    floors_min: 17, floors_max: 26, build_status: :under_construction },

  # gollandia.marmax.ru + erzrf.ru/novostroyki/11420993001
  # Не путать с «Голландия. Верхний сад» (Касимовское ш., 1, ввод 2028) —
  # это отдельный проект того же застройщика.
  { slug: 'gollandiya-parkovyy-kvartal', name: 'Голландия. Парковый квартал',
    district_slug: 'kalnoe', developer: 'Мармакс',
    address: 'Рязань, Касимовское шоссе',
    address_patterns: ['ш. Касимовское, д. 22'],
    floors_min: 6, floors_max: 16, build_status: :completed },

  # belyi-gorod.ru/buildings/staroe-selo-dom-1 + ryazan.cian.ru/zhiloy-kompleks-po-ul-staroe-selo-ryazan-39822
  # В прошлой редакции значился как «Дашково-Песочня, Старое Село 2» —
  # это был адрес дома, а не название комплекса.
  { slug: 'staroe-selo', name: 'Старое Село', district_slug: 'dashkovo-pesochnya',
    developer: 'Белый город', address: 'Рязань, ул. Старое Село, 1 и 2',
    address_patterns: ['ул. Старое Село'],
    buildings_count: 3, floors_min: 13, floors_max: 21,
    wall_material: 'кирпично-монолитный', build_status: :completed },

  # ryazan.cian.ru/zhiloy-kompleks-smart-kvartal-leto-ryazan-7058 + realty.yandex.ru/ryazan/.../leto-929987
  # Полное имя по ЦИАН — «СМАРТ квартал Лето»; берём короткое, под которым
  # ЖК ищут и под которым он идёт у нас в карточках. Район — nil: Михайловское
  # шоссе в реестре микрорайонов не заведено.
  { slug: 'leto', name: 'Лето', district_slug: nil,
    developer: 'Капитал Строитель Жилья', address: 'Рязань, ул. Брестская',
    address_patterns: ['ул. Брестская, д. 1', 'ул. Брестская, д. 5'],
    built_to: 2022, buildings_count: 3, floors_max: 25, build_status: :completed }
].freeze

created = 0
updated = 0

seed_complexes.each do |attrs|
  complex = ResidentialComplex.unscoped.find_or_initialize_by(slug: attrs[:slug])
  was_new = complex.new_record?

  # Идемпотентность: заполняем только пустое. Всё, что мог править редактор
  # (название, район, фактура, body_blocks, published), не перетираем —
  # иначе прогон сида откатывал бы правки из админки.
  #
  # `blank?`, а не `||=`: у `address_patterns` дефолт `[]` — истинное
  # значение, и `||=` молча пропускал бы заполнение пустого массива.
  attrs.each do |field, value|
    next if field == :slug || value.nil?

    complex.public_send(:"#{field}=", value) if complex.public_send(field).blank?
  end

  complex.city ||= 'Рязань'
  complex.published = false if was_new

  if complex.changed?
    complex.save!
    was_new ? created += 1 : updated += 1
  end
end

puts "[zhk:seed] создано: #{created}, обновлено: #{updated}, всего в справочнике: #{ResidentialComplex.count}"
