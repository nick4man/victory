# frozen_string_literal: true

FactoryBot.define do
  factory :activation_event do
    association :user
    channel { 'inbound' }
    happened_at { Time.current }

    trait :inbound do
      channel { 'inbound' }
    end
    trait :cabinet_profile do
      channel { 'cabinet_profile' }
    end
    trait :admin_panel do
      channel { 'admin_panel' }
    end
    trait :bulk_pdf do
      channel { 'bulk_pdf' }
    end
  end
end
