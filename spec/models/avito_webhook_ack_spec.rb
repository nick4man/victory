# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AvitoWebhookAck, type: :model do
  subject { build(:avito_webhook_ack) }

  it { is_expected.to validate_presence_of(:message_id) }
  it { is_expected.to validate_uniqueness_of(:message_id) }
  it { is_expected.to validate_presence_of(:processed_at) }
end
