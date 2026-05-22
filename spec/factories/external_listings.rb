# frozen_string_literal: true

FactoryBot.define do
  factory :external_listing do
    source { 'yandex_yrl' }
    sequence(:source_id) { |n| "yrl-listing-#{n}-#{SecureRandom.hex(4)}" }
    url { Faker::Internet.url }
    title { "#{rand(1..5)}-комн. квартира, #{Faker::Address.street_address}" }
    price { Faker::Number.between(from: 2_500_000, to: 12_000_000) }
    area { Faker::Number.between(from: 30.0, to: 120.0) }
    rooms { rand(1..5) }
    floor { rand(1..9) }
    total_floors { rand(5..16) }
    property_type { 'flat' }
    deal_type { 'sale' }
    fetched_at { Time.current }
    raw_payload { {} }

    trait :agency_sitemap do
      source { 'agency_sitemap' }
      sequence(:source_id) { |n| "cian_961:listing-#{n}" }
    end

    trait :yandex_yrl do
      source { 'yandex_yrl' }
    end

    trait :with_agency_host do
      source { 'yandex_yrl' }
      url { 'https://agency.example.ru/listing/123' }
    end

    trait :closed do
      closed_at { 1.week.ago }
    end
  end
end
