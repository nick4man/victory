# frozen_string_literal: true

FactoryBot.define do
  factory :inquiry do
    association :property

    name { Faker::Name.full_name }
    sequence(:phone) { |n| "7995#{n.to_s.rjust(7, '0')}" }
    email { Faker::Internet.email }
    message { Faker::Lorem.sentence(word_count: 10) }
    inquiry_type { :viewing }
    status { :new }
    source { 'web' }

    trait :viewing do
      inquiry_type { :viewing }
    end

    trait :consultation do
      inquiry_type { :consultation }
    end

    trait :callback do
      inquiry_type { :callback }
      email { nil }
    end

    trait :contacted do
      status { :contacted }
    end

    trait :completed do
      status { :completed }
      completed_at { Time.current }
    end

    trait :cancelled do
      status { :cancelled }
      cancelled_at { Time.current }
    end

    trait :with_user do
      association :user
    end

    trait :with_agent do
      association :agent, factory: [:user, :agent]
    end

    trait :high_priority do
      priority { :high }
    end
  end
end
