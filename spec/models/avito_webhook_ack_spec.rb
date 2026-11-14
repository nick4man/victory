# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AvitoWebhookAck, type: :model do
  subject { build(:avito_webhook_ack) }

  it { is_expected.to validate_presence_of(:message_id) }
  it { is_expected.to validate_uniqueness_of(:message_id) }
  it { is_expected.to validate_presence_of(:processed_at) }

  it 'поддерживает мягкое удаление через default_scope' do
    ack = create(:avito_webhook_ack)
    ack.update!(deleted_at: Time.current)

    expect(AvitoWebhookAck.find_by(id: ack.id)).to be_nil
    expect(AvitoWebhookAck.unscoped.find(ack.id)).to eq(ack)
  end
end
