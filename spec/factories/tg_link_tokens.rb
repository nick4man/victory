# frozen_string_literal: true

FactoryBot.define do
  factory :tg_link_token do
    association :user
    token      { SecureRandom.urlsafe_base64(32) }
    expires_at { TgLinkToken::TTL.from_now }

    trait :expired do
      expires_at { 1.minute.ago }
    end

    trait :consumed do
      consumed_at { 5.minutes.ago }
    end
  end
end
