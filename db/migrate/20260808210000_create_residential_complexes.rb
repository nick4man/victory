# frozen_string_literal: true

# A2 — SEO-слой по жилым комплексам (08.08.26).
#
# Справочник ЖК: собственный источник правды. Из Topnlab название ЖК не
# приходит вообще (`@p['building']` в PropertyMapper — это номер строения,
# а признак первички `is_first_sale` схлопнут в `is_featured`), поэтому
# карточка ЖК наполняется редактором через админку.
#
# Страница ЖК — entity-страница под бренд-запросы («ЖК Легенда Рязань»),
# а не фасет intent×type. Поэтому редакционный контент лежит здесь же
# (`body_blocks`), а не пятой осью в `landing_contents`, чей уникальный
# индекс (intent, type, district_slug, rooms) описывает именно фасет.
#
# Механика блоков переиспользуется как есть: concern RendersLandingBlocks
# пре-рендерит body_html (страница) и body_plain (контекст чат-бота).
class CreateResidentialComplexes < ActiveRecord::Migration[7.1]
  def change
    create_table :residential_complexes do |t|
      t.string :name, null: false                      # «Легенда» — без префикса «ЖК»
      t.string :slug                                   # friendly_id, транслит кириллицы
      t.string :city, null: false, default: 'Рязань'   # каноническое имя из Cities::REGISTRY
      t.string :district_slug                          # ключ RyazanDistricts::MICRO
      t.string :developer                              # «Единство»
      t.string :address                                # «ул. Костычева, 8»

      # Подсказчик привязки объектов (Zhk::AttachmentSuggester) матчит
      # Property#address по этим паттернам. Пусто → работает только
      # фильтр по району.
      t.string :address_patterns, array: true, default: []

      t.decimal :latitude,  precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6

      t.integer :built_from                            # год ввода первой очереди
      t.integer :built_to                              # год ввода последней очереди
      t.integer :buildings_count                       # корпусов
      t.integer :floors_min
      t.integer :floors_max
      t.string  :wall_material                         # словарь совпадает с Property#building_type

      t.integer :housing_class                         # enum: эконом/комфорт/бизнес/элит
      t.integer :build_status                          # enum: проектируется/строится/сдан

      t.boolean :has_parking,      default: false, null: false
      t.boolean :has_closed_yard,  default: false, null: false
      t.boolean :has_playground,   default: false, null: false
      t.boolean :has_kindergarten, default: false, null: false
      t.boolean :has_school,       default: false, null: false

      t.string :title                                  # ручной override <title>
      t.string :meta_description, limit: 300

      t.jsonb :body_blocks, default: []
      t.text  :body_html                               # пре-рендер для страницы
      t.text  :body_plain                              # пре-рендер для чат-бота

      t.boolean  :published, default: false, null: false
      t.datetime :deleted_at                           # soft-delete (правило #1 CLAUDE.md)

      t.timestamps
    end

    add_index :residential_complexes, :slug, unique: true
    add_index :residential_complexes, %i[city district_slug]
    add_index :residential_complexes, :published
    add_index :residential_complexes, :deleted_at
  end
end
