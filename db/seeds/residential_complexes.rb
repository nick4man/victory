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
# ДП, ул. Льговская, д. 10, кв. 469»). Номер дома обязателен там, где улица
# общая для нескольких ЖК: «Северный» и «Пожарский» стоят на одной Зубковой,
# и уличный паттерн склеил бы их инвентарь в одну кучу. Где улица принадлежит
# одному ЖК целиком («Скобелев», «Видный», «Метропарк») — хватает улицы.
#
# Короткие номера («д. 1», «д. 4») подстрокой ловят и «д. 10»-«д. 19»,
# «д. 40»-«д. 49» на той же улице. Оставлено намеренно: ограничитель-запятая
# («д. 1,») промахнётся по адресу, где номер дома последний и запятой за ним
# нет. Ложный кандидат стоит редактору одного взгляда — привязка ручная,
# `by_patterns` только предлагает; пропущенный объект не покажется вовсе.
#
# 🚨 Переименование ЖК — это правка через админку, а НЕ смена ключа `slug:`
# здесь. `find_or_initialize_by(slug:)` старую запись по новому слагу не
# найдёт и создаст дубль, осиротив прежнюю. Пока справочник стоял пустым,
# это было безвредно; с 07.09.26 на проде 12 записей.

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
  # 08.09.26: обе ссылки живы (ЦИАН отдаёт 301 на zhk-legenda-ryazan-i.cian.ru).
  # Но источники расходятся в НОМЕРЕ ДОМА: у застройщика на /building/96 —
  # «ул. Интернациональная, 19а», у ЦИАН — «Интернациональная улица, 20».
  # Оставляем 20 (совпадает с адресами каталога и с address_patterns), однако
  # в редакционном тексте номер не приводим — см. db/seeds/zhk_texts.rb.
  # Решение владельца 08.09.26: это не спор источников, а два адреса одного
  # дома — 19а строительный, 20 почтовый. Поэтому поле не обнуляем, в отличие
  # от «Приокского парка» ниже: там источники расходятся по существу, здесь —
  # по назначению адреса.
  { slug: 'legenda', name: 'Легенда', district_slug: 'kanishchevo',
    developer: 'Единство', address: 'Рязань, ул. Интернациональная, 20',
    address_patterns: ['ул. Интернациональная, д. 20'],
    built_to: 2023, floors_min: 17, floors_max: 23,
    wall_material: 'монолитно-кирпичный', build_status: :completed },

  # erzrf.ru/novostroyki/zhk-priokskij-park-565601001 + ryazan.cian.ru/zhiloy-kompleks-priokskiy-park-ryazan-38832
  #
  # 🚨 Проверка 08.09.26. Обе ссылки рабочие: ЕРЗ отдаёт карточку (ID 565601001,
  # бренд ГК «Единство», застройщик ООО «Приокский парк»), ЦИАН — 301 на
  # zhk-priokskiy-park-ryazan-i.cian.ru. Но данные ниже НЕ подтвердились:
  #   built_to 2026 + :under_construction ↔ ЦИАН пишет «Сдан», срок 2016–2017;
  #   floors 3–18                          ↔ ЦИАН пишет 11–18.
  # Косвенно за ЦИАН: своей страницы у ЖК на сайте застройщика нет, и в
  # каталогах /realestate и /readyestate он не значится — только старые
  # пресс-материалы. Карточка ЕРЗ спор не решает: «стоит в очереди на сбор
  # данных», сроков и этажности в ней нет.
  # Расхождение не разрешено. Редакционный текст его обходит (года, стадии и
  # этажности в нём нет), но фактурная карточка на /zhk/priokskiy-park всё
  # ещё отдаёт цифры ниже. Пока поля не выверены редактором по проектной
  # декларации (наш.дом.рф) страницу публиковать нельзя.
  #
  # Решение владельца 08.09.26: спорное обнуляем — по тому же правилу, что и
  # везде в этом файле. Разница между «сдан в 2017» и «строится, ввод 2026»
  # не косметическая: она определяет, что человек вообще покупает. Ошибиться
  # тут хуже, чем промолчать, а промолчать честнее, чем выбрать источник
  # наугад. `buildings_count` оставлен: два корпуса подтверждают оба источника.
  #
  # ⚠️ Сид дозаполняет только пустое, поэтому убрать поля отсюда мало —
  # в проде значения уже стоят. Их очистка сделана отдельно, вручную.
  { slug: 'priokskiy-park', name: 'Приокский парк', district_slug: 'priokskiy',
    developer: 'Единство', address: 'Рязань, ул. Октябрьская, 65Б',
    address_patterns: ['ул. Октябрьская, д. 65'],
    buildings_count: 2 },

  # edinstvo62.ru/building/81 и /82 + ryazan.etagi.com/zastr/jk/vidnyjj-2378
  # Стадию не ставим: очереди сданы вразнобой, единой даты у источников нет.
  { slug: 'vidnyy', name: 'Видный', district_slug: 'semchino',
    developer: 'Единство', address: 'Рязань, ул. Княжье Поле, 1Б',
    address_patterns: ['ул. Княжье Поле', 'ул. Рыбновская'] },

  # otkrytie62.ru (сайт объекта) + edinstvo62.ru/complex/55
  # Домен исправлен 08.09.26: «otkritie62.ru» не резолвится вовсе, рабочий —
  # через `y`. /complex/55 отдаёт 301 на /complex/otkrytie, нужен `curl -L`.
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
  # Тот же случай, что у «Пожарского»: застройщик по ДДУ — проектная компания
  # СЗ «Старт», в продаже и в выдаче объект идёт как «Единство». Ставим бренд,
  # потому что клиент ищет по нему.
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

  # Идемпотентность: сид ВЛАДЕЕТ записью только в момент создания. Новой
  # проставляем всю фактуру, существующую дозаполняем лишь там, где
  # значения не было никогда — то есть строго по `nil`.
  #
  # Почему не `blank?`: пустая строка и пустой массив — это не «данных
  # нет», а решение редактора. Админка сознательно позволяет очистить
  # `address_patterns` пустой textarea (см. комментарий к
  # `Admin::ResidentialComplexesController#normalized_params`), и прогон
  # на `blank?` восстанавливал бы стёртые паттерны поверх этой правки.
  #
  # Почему не `||=`: у `address_patterns` дефолт `[]` — значение истинное,
  # и на создании `||=` молча пропускал бы заполнение. Отсюда две ветки,
  # а не одно условие.
  attrs.each do |field, value|
    next if field == :slug || value.nil?
    next unless was_new || complex.public_send(field).nil?

    complex.public_send(:"#{field}=", value)
  end

  complex.city ||= 'Рязань'
  complex.published = false if was_new

  if complex.changed?
    complex.save!
    was_new ? created += 1 : updated += 1
  end
end

puts "[zhk:seed] создано: #{created}, обновлено: #{updated}, всего в справочнике: #{ResidentialComplex.count}"
