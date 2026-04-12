# frozen_string_literal: true

FactoryBot.define do
  factory :property_type do
    sequence(:name) { |n| "Тип #{n}" }
    sequence(:slug) { |n| "type-#{n}" }

    trait :apartment do
      name { 'Квартира' }
      slug { 'apartment' }
    end

    trait :house do
      name { 'Дом' }
      slug { 'house' }
    end

    trait :commercial do
      name { 'Коммерческая' }
      slug { 'commercial' }
    end
  end
end
