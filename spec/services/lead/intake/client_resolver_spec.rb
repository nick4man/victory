# frozen_string_literal: true

require 'rails_helper'

# Phase 4H — Cross-channel client identity resolver. Pure lookup, не
# мутирует state. Тестируем: normalize utilities (phone/email) +
# match priority (phone > tg_user_id > email) + 90d window + spam exclusion.
RSpec.describe Lead::Intake::ClientResolver do
  describe '.normalize_phone' do
    it 'returns 11-digit E.164 для full Russian phone with +' do
      expect(described_class.normalize_phone('+7 (999) 123-45-67')).to eq('79991234567')
    end

    it 'converts 8-prefix to 7-prefix' do
      expect(described_class.normalize_phone('89991234567')).to eq('79991234567')
    end

    it 'prepends 7 to 10-digit local number' do
      expect(described_class.normalize_phone('9991234567')).to eq('79991234567')
    end

    it 'returns nil for too-short input' do
      expect(described_class.normalize_phone('123')).to be_nil
    end

    it 'returns nil for blank' do
      expect(described_class.normalize_phone('')).to be_nil
      expect(described_class.normalize_phone(nil)).to be_nil
    end

    it 'handles already-normalized input' do
      expect(described_class.normalize_phone('79991234567')).to eq('79991234567')
    end
  end

  describe '.normalize_email' do
    it 'strips + downcases' do
      expect(described_class.normalize_email(' John@Example.COM ')).to eq('john@example.com')
    end

    it 'returns nil for malformed' do
      expect(described_class.normalize_email('not-an-email')).to be_nil
    end

    it 'returns nil for blank' do
      expect(described_class.normalize_email(nil)).to be_nil
      expect(described_class.normalize_email('')).to be_nil
    end
  end

  describe '.find — match priority' do
    let!(:site_inquiry) do
      Inquiry.create!(
        inquiry_type: 'quick_inquiry', name: 'Анна Сайт',
        phone: '+79991234567', message: 'site form',
        source: 'site_form', status: 'new',
        client_phone_e164: '79991234567',
        client_email_norm: 'anna@example.com',
        attribution_source: 'site_form'
      )
    end

    let!(:tg_inquiry) do
      Inquiry.create!(
        inquiry_type: 'quick_inquiry', name: 'Борис TG',
        message: 'tg dm', source: 'tg_dm', status: 'new',
        client_tg_user_id: 777_999,
        attribution_source: 'tg_dm'
      )
    end

    it 'matches by phone E.164 first (highest confidence 0.95)' do
      result = described_class.find(phone: '+7 999 123-45-67', tg_user_id: 777_999, email: nil)
      expect(result.matched?).to be(true)
      expect(result.match_strategy).to eq('phone_e164')
      expect(result.confidence).to eq(0.95)
      expect(result.inquiry).to eq(site_inquiry)
    end

    it 'matches by tg_user_id when phone absent (confidence 0.90)' do
      result = described_class.find(phone: nil, tg_user_id: 777_999, email: nil)
      expect(result.match_strategy).to eq('tg_user_id')
      expect(result.confidence).to eq(0.90)
      expect(result.inquiry).to eq(tg_inquiry)
    end

    it 'matches by email when phone + tg absent (confidence 0.70)' do
      result = described_class.find(phone: nil, tg_user_id: nil, email: 'Anna@Example.com')
      expect(result.match_strategy).to eq('email')
      expect(result.confidence).to eq(0.70)
      expect(result.inquiry).to eq(site_inquiry)
    end

    it 'returns no-match when nothing matches' do
      result = described_class.find(phone: '+71111111111', tg_user_id: 88_888, email: 'unknown@x.com')
      expect(result.matched?).to be(false)
      expect(result.inquiry).to be_nil
      expect(result.confidence).to eq(0.0)
    end

    it 'returns no-match when all inputs blank' do
      result = described_class.find(phone: nil, tg_user_id: nil, email: nil)
      expect(result.matched?).to be(false)
    end
  end

  describe '.find — 90d window' do
    it 'excludes inquiries older than 90 days' do
      Inquiry.create!(
        inquiry_type: 'quick_inquiry', name: 'Old',
        phone: '+79991234567', message: 'old',
        source: 'site_form', status: 'new',
        client_phone_e164: '79991234567',
        created_at: 91.days.ago, updated_at: 91.days.ago
      ).update_columns(created_at: 91.days.ago)

      result = described_class.find(phone: '+79991234567', tg_user_id: nil, email: nil)
      expect(result.matched?).to be(false)
    end
  end

  describe '.find — spam/cancelled exclusion' do
    it 'excludes spam status' do
      Inquiry.create!(
        inquiry_type: 'quick_inquiry', name: 'Spam',
        phone: '+72222222222', message: 'spam',
        source: 'tg_dm', status: 'spam',
        client_phone_e164: '72222222222'
      )
      result = described_class.find(phone: '+72222222222', tg_user_id: nil, email: nil)
      expect(result.matched?).to be(false)
    end

    it 'excludes cancelled status' do
      Inquiry.create!(
        inquiry_type: 'quick_inquiry', name: 'Cancelled',
        phone: '+73333333333', message: 'cancelled',
        source: 'tg_dm', status: 'cancelled',
        client_phone_e164: '73333333333'
      )
      result = described_class.find(phone: '+73333333333', tg_user_id: nil, email: nil)
      expect(result.matched?).to be(false)
    end
  end

  describe 'Result struct' do
    it '#matched? = true when inquiry present' do
      r = described_class::Result.new(inquiry: Object.new, match_strategy: 'phone_e164', confidence: 0.95)
      expect(r.matched?).to be(true)
    end

    it '#matched? = false when inquiry nil' do
      r = described_class::Result.new(inquiry: nil, confidence: 0.0)
      expect(r.matched?).to be(false)
    end
  end
end
