# frozen_string_literal: true

FactoryBot.define do
  factory :avito_message do
    sequence(:message_id) { |n| "msg_#{n}" }
    sequence(:chat_id)    { |n| "chat_#{n}" }
    author_id             { 987_654 }
    user_id               { 123_456 }
    item_id               { 111_222_333 }
    content_type          { 'text' }
    content_text          { 'Здравствуйте, можно посмотреть квартиру?' }
    payload               { { 'id' => message_id, 'content' => { 'text' => content_text } } }
    direction             { 'incoming' }
  end
end
