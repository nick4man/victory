# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { 'Password123!' }
    password_confirmation { 'Password123!' }
    first_name { Faker::Name.first_name }
    last_name { Faker::Name.last_name }
    sequence(:phone) { |n| "7999#{n.to_s.rjust(7, '0')}" }
    role { :client }
    confirmed_at { Time.current }
    active { true }

    trait :admin do
      role { :admin }
      email { 'admin@viktory-realty.ru' }
    end

    trait :agent do
      role { :agent }
    end

    trait :client do
      role { :client }
    end

    trait :unconfirmed do
      confirmed_at { nil }
    end

    trait :inactive do
      active { false }
    end
  end
end
