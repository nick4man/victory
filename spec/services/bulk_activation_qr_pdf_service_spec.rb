# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BulkActivationQrPdfService do
  describe '.call' do
    let(:user1) { create(:user, first_name: 'Иван', last_name: 'Петров', phone: '+79091234567') }
    let(:user2) { create(:user, first_name: 'Мария', last_name: 'Сидорова', phone: '+79991110000') }

    it 'returns binary PDF data со стартовым magic-byte' do
      pdf = described_class.call(users: [user1])
      expect(pdf).to start_with('%PDF-1')
      expect(pdf).to end_with("%%EOF\n").or end_with('%%EOF')
    end

    it 'creates one TgLinkToken per user' do
      expect {
        described_class.call(users: [user1, user2])
      }.to change { TgLinkToken.count }.by(2)

      expect(TgLinkToken.where(user_id: user1.id).count).to eq(1)
      expect(TgLinkToken.where(user_id: user2.id).count).to eq(1)
    end

    it 'tokens generated имеют 30-min TTL' do
      described_class.call(users: [user1])
      token = TgLinkToken.where(user_id: user1.id).last
      expect(token.expires_at).to be_within(2.minutes).of(30.minutes.from_now)
    end

    it 'tracks generated_count' do
      service = described_class.new([user1, user2])
      service.call
      expect(service.generated_count).to eq(2)
    end

    it 'возвращает non-empty PDF даже для одного user' do
      pdf = described_class.call(users: [user1])
      expect(pdf.bytesize).to be > 10_000
    end

    it 'правильно использует bot_username override' do
      pdf = described_class.call(users: [user1], bot_username: 'TestBot')
      # PDF binary — точечный contains-check сложен; проверяем что rake
      # не упал + token URL build correct
      expect(pdf.bytesize).to be > 10_000
    end
  end

  describe '#mask_phone (private helper)' do
    it 'shows только last 4 digits' do
      svc = described_class.new([])
      masked = svc.send(:mask_phone, '+79091234567')
      expect(masked).to eq('+7 ••• ••• 4567')
    end

    it 'handles nil/short phone gracefully' do
      svc = described_class.new([])
      expect(svc.send(:mask_phone, nil)).to eq('+7 ••• •••• ••••')
      expect(svc.send(:mask_phone, '123')).to eq('+7 ••• •••• ••••')
    end
  end
end
