# frozen_string_literal: true

FactoryBot.define do
  factory :inquiry do
    inquiry_type { 'quick_inquiry' }
    status { 'new' }
    name { Faker::Name.name }
    phone { "7#{Faker::Number.number(digits: 10)}" }
    message { Faker::Lorem.sentence }
    source { 'site_form' }
    metadata { {} }

    # Suppress noisy after_create callbacks during testing.
    # The callbacks that fire TG push / CRM sync / agent assignment
    # are tested in their own specs and not relevant to referral flow.
    after(:build) do |inquiry|
      inquiry.define_singleton_method(:push_to_work_bot) { nil }
      inquiry.define_singleton_method(:assign_to_agent)  { nil }
      inquiry.define_singleton_method(:send_notifications) { nil }
      inquiry.define_singleton_method(:sync_to_crm)      { nil }
    end

    trait :with_external_listing do
      association :external_listing
      # auto_create_referral callback fires — callers that need to suppress it
      # should stub Referrals::AutoCreator.call before factory create.
      after(:build) do |inquiry|
        inquiry.define_singleton_method(:auto_create_referral) { nil }
      end
    end
  end
end
