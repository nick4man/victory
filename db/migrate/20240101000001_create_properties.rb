# frozen_string_literal: true

class CreateProperties < ActiveRecord::Migration[7.1]
  def change
    create_table :properties do |t|
      # Basic Information
      t.string :title, null: false
      t.text :description
      t.string :slug, index: { unique: true }
      
      # Pricing
      t.decimal :price, precision: 15, scale: 2, null: false
      t.decimal :price_per_sqm, precision: 10, scale: 2
      
      # Type and Deal
      t.integer :deal_type, default: 0, null: false # 0: sale, 1: rent
      t.integer :status, default: 0, null: false # 0: draft, 1: active, 2: sold, 3: archived
      
      # Associations
      t.references :user, null: false, foreign_key: true
      t.references :property_type, foreign_key: false # Will be added later when property_types table exists
      
      # Property Characteristics
      t.decimal :area, precision: 10, scale: 2, null: false # Общая площадь
      t.decimal :living_area, precision: 10, scale: 2 # Жилая площадь
      t.decimal :kitchen_area, precision: 10, scale: 2 # Площадь кухни
      
      t.integer :rooms # Количество комнат
      t.integer :bedrooms # Количество спален
      t.integer :bathrooms # Количество санузлов
      
      t.integer :floor # Этаж
      t.integer :total_floors # Всего этажей в здании
      
      # Building Information
      t.integer :building_year # Год постройки
      t.string :building_type # Тип здания (панель, кирпич, монолит)
      t.integer :condition, default: 1 # 0: needs_repair, 1: normal, 2: renovated, 3: euro
      
      # Location
      t.string :address, null: false
      t.string :district # Район
      t.string :metro_station # Ближайшая станция метро
      t.integer :metro_distance # Расстояние до метро (в метрах)
      t.string :metro_transport # Тип транспорта до метро (пешком, транспорт)
      
      # Geocoding
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      
      # Features & Amenities (Boolean)
      t.boolean :has_balcony, default: false
      t.boolean :has_loggia, default: false
      t.boolean :has_parking, default: false
      t.boolean :has_elevator, default: false
      t.boolean :has_garbage_chute, default: false
      t.boolean :has_security, default: false
      t.boolean :has_concierge, default: false
      t.boolean :pets_allowed, default: false
      
      # Utilities
      t.boolean :has_gas, default: false
      t.boolean :has_water, default: true
      t.boolean :has_electricity, default: true
      t.boolean :has_heating, default: true
      
      # Additional
      t.string :ceiling_height # Высота потолков
      t.string :window_view # Вид из окна
      t.string :furniture # Мебель (да/нет/частично)
      t.string :appliances # Техника
      
      # Legal & Documents
      t.string :ownership_type # Тип собственности
      t.integer :owners_count # Количество собственников
      t.boolean :encumbrance, default: false # Обременение
      t.boolean :mortgage_allowed, default: true # Возможна ипотека
      
      # Media
      t.string :video_url # Ссылка на видео
      t.string :virtual_tour_url # Ссылка на виртуальный тур
      t.integer :images_count, default: 0 # Счетчик изображений
      
      # Stats & Tracking
      t.integer :views_count, default: 0, null: false
      t.integer :favorites_count, default: 0, null: false
      t.integer :inquiries_count, default: 0, null: false
      t.integer :phone_views_count, default: 0, null: false
      
      # Pricing History
      t.decimal :original_price, precision: 15, scale: 2 # Первоначальная цена
      t.datetime :price_changed_at # Дата последнего изменения цены
      
      # SEO
      t.string :meta_title
      t.text :meta_description
      t.string :meta_keywords
      
      # Publishing
      t.datetime :published_at
      t.datetime :expires_at # Дата окончания публикации
      
      # Featured
      t.boolean :is_featured, default: false # Избранное/премиум
      t.integer :featured_order, default: 0 # Порядок сортировки в избранном
      
      # Moderation
      t.datetime :moderated_at
      t.references :moderated_by, foreign_key: { to_table: :users }
      t.text :moderation_notes
      
      # Soft delete
      t.datetime :deleted_at
      
      t.timestamps
    end
    
    # Indexes for performance
    add_index :properties, :deal_type
    add_index :properties, :status
    add_index :properties, :price
    add_index :properties, :area
    add_index :properties, :rooms
    add_index :properties, :district
    add_index :properties, :metro_station
    add_index :properties, [:latitude, :longitude]
    add_index :properties, :published_at
    add_index :properties, :is_featured
    add_index :properties, :deleted_at
    add_index :properties, :created_at
    add_index :properties, [:status, :deal_type, :price]
    add_index :properties, [:status, :is_featured, :created_at]
  end
end