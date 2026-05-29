# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user-#{n}-#{SecureRandom.hex(3)}@victory62.test" }
    sequence(:phone) { |n| "+79#{(900_000_000 + n).to_s.rjust(9, '0').last(9)}" }
    first_name { Faker::Name.first_name }
    last_name  { Faker::Name.last_name }
    role { :client }
    active { true }
    password { 'placeholder-pwd-' + SecureRandom.hex(8) }

    trait :tg_linked do
      sequence(:tg_user_id) { |n| 100_000_000 + n }
      sequence(:tg_username) { |n| "client_#{n}" }
      tg_linked_at { 1.day.ago }
    end
  end
end
