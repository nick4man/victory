# frozen_string_literal: true

# Город происхождения объявления. До этой миграции у ExternalListing не было
# колонки city — ComparableFinder#external_scope не мог отфильтровать чужие
# города, и рязанские объявления ЦАН (961-961.ru) попадали в аналоги для
# оценок в СПб/Москве (issue #172).
#
# Бэкфилл статический, без сети: yandex_yrl / agency_sitemap / topnlab_mls —
# по определению рязанские фиды (см. комментарий в ExternalListing).
# avito/cian (Tavily websearch) могут быть из любого города — city остаётся
# NULL, ComparableFinder их не берёт пока запись не пересохранится с городом.
class AddCityToExternalListings < ActiveRecord::Migration[8.1]
  def up
    add_column :external_listings, :city, :string
    add_index :external_listings, :city

    execute <<~SQL.squish
      UPDATE external_listings
      SET city = 'Рязань'
      WHERE city IS NULL AND source IN ('yandex_yrl', 'agency_sitemap', 'topnlab_mls')
    SQL
  end

  def down
    remove_index :external_listings, :city
    remove_column :external_listings, :city
  end
end
