# frozen_string_literal: true

FactoryBot.define do
  factory :referral do
    association :inquiry, factory: %i[inquiry with_external_listing]
    association :partner_agency
    association :external_listing
    status { 'pending' }
    commission_rate { nil }
    metadata { {} }

    trait :pending do
      status { 'pending' }
    end

    trait :forwarded do
      status { 'forwarded' }
      forwarded_at { Time.current }
    end

    trait :in_progress do
      status { 'in_progress' }
    end

    trait :closed_won do
      status { 'closed_won' }
      closed_at { Time.current }
      final_commission_amount { 150_000.00 }
    end

    trait :closed_lost do
      status { 'closed_lost' }
      closed_at { Time.current }
    end

    trait :stale do
      status { 'stale' }
    end

    trait :with_commission_rate do
      commission_rate { 0.30 }
    end

    trait :deleted do
      deleted_at { 1.day.ago }
    end
  end
end
