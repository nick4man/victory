# frozen_string_literal: true

FactoryBot.define do
  factory :avito_webhook_ack do
    sequence(:message_id) { |n| "ack_#{n}" }
    processed_at { Time.current }
  end
end
