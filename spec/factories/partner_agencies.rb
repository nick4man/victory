# frozen_string_literal: true

FactoryBot.define do
  factory :partner_agency do
    sequence(:name) { |n| "Агентство «#{Faker::Company.name}» #{n}" }
    sequence(:slug) { |n| "agency-#{n}-#{SecureRandom.hex(4)}" }
    status { 'active' }
    feed_source_key { nil }
    default_commission_rate { nil }
    contact_email { nil }
    metadata { {} }

    trait :with_default_commission do
      default_commission_rate { 0.30 }
    end

    trait :with_feed_key do
      sequence(:feed_source_key) { |n| "feed_key_#{n}" }
    end

    trait :inactive do
      status { 'inactive' }
    end

    trait :blocked do
      status { 'blocked' }
    end

    trait :deleted do
      deleted_at { 1.day.ago }
    end
  end
end
