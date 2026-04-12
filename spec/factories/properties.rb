# frozen_string_literal: true

FactoryBot.define do
  factory :property do
    association :user, factory: [:user, :agent]
    association :property_type, factory: [:property_type, :apartment]

    sequence(:title) { |n| "#{n}-комнатная квартира в Москве" }
    description { Faker::Lorem.paragraph(sentence_count: 3) }
    price { rand(5_000_000..50_000_000) }
    area { rand(30..150) }
    rooms { rand(1..5) }
    floor { rand(1..20) }
    total_floors { rand(5..25) }
    address { "Москва, #{Faker::Address.street_name}, д. #{rand(1..100)}" }
    district { %w[Центральный Арбат Тверской Замоскворечье Хамовники Сокольники].sample }
    deal_type { :sale }
    status { :draft }
    condition { :normal }
    building_year { rand(1970..2023) }
    building_type { %w[монолит кирпич панель].sample }

    trait :active do
      status { :active }
      published_at { 1.day.ago }
    end

    trait :featured do
      status { :active }
      published_at { 1.day.ago }
      is_featured { true }
    end

    trait :for_rent do
      deal_type { :rent }
      price { rand(30_000..200_000) }
    end

    trait :for_sale do
      deal_type { :sale }
    end

    trait :with_metro do
      metro_station { %w[Арбатская Тверская Таганская Сокольники].sample }
      metro_distance { rand(100..1000) }
    end

    trait :sold do
      status { :sold }
    end

    trait :draft do
      status { :draft }
    end
  end
end
