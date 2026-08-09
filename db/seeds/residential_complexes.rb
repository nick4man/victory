# frozen_string_literal: true

# A2 — стартовый справочник ЖК (08.08.26). Запуск: `rake zhk:seed`.
# НЕ подключён в db/seeds.rb — прод-сиды не должны прогоняться автоматом.
#
# Источник названий — редакционные партиалы лендингов районов
# (app/views/landings/content/_sale_kvartira_*.html.erb). Это маркетинговая
# проза, а не верифицированный реестр, поэтому фактура (застройщик кроме
# явно названного, годы, класс, этажность) НЕ заполняется: неверные факты
# на entity-странице хуже отсутствующих и прямо ведут к «недостоверная
# информация» в Я.Вебмастере. Редактор дозаполняет через админку, сверяясь
# с сайтом застройщика / наш.дом.рф, и только потом публикует.
#
# «ЖК на Циолковского» (_sale_kvartira_centr.html.erb:12) сознательно
# пропущен — это оборот речи, а не название комплекса.

SEED_COMPLEXES = [
  { slug: 'priokskiy-park', name: 'Приокский парк',                 district_slug: 'priokskiy',          developer: 'Единство' },
  { slug: 'legenda',        name: 'Легенда',                        district_slug: 'kanishchevo',        developer: nil },
  { slug: 'vidnyy',         name: 'Видный',                         district_slug: 'semchino',           developer: nil },
  { slug: 'metropark',      name: 'Метропарк',                      district_slug: 'semchino',           developer: nil },
  { slug: 'skobelev',       name: 'Скобелев',                       district_slug: 'dashkovo-pesochnya', developer: 'Единство' },
  { slug: 'otkrytie',       name: 'Открытие',                       district_slug: 'dashkovo-pesochnya', developer: nil },
  { slug: 'staroe-selo-2',  name: 'Дашково-Песочня, Старое Село 2',  district_slug: 'dashkovo-pesochnya', developer: nil }
].freeze

created = 0
updated = 0

SEED_COMPLEXES.each do |attrs|
  complex = ResidentialComplex.unscoped.find_or_initialize_by(slug: attrs[:slug])
  was_new = complex.new_record?

  # Идемпотентность: трогаем только справочные поля. Всё, что мог править
  # редактор (body_blocks, published, фактура), не перетираем.
  complex.name          = attrs[:name]
  complex.district_slug = attrs[:district_slug]
  complex.developer   ||= attrs[:developer]
  complex.city        ||= 'Рязань'
  complex.published     = false if was_new

  if complex.changed?
    complex.save!
    was_new ? created += 1 : updated += 1
  end
end

puts "[zhk:seed] создано: #{created}, обновлено: #{updated}, всего в справочнике: #{ResidentialComplex.count}"
