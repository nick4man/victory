# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PhoneStopList do
  describe '.normalize' do
    it 'extracts last 10 digits from various formats' do
      expect(described_class.normalize('+79009694844')).to eq('9009694844')
      expect(described_class.normalize('8 (900) 969-48-44')).to eq('9009694844')
      expect(described_class.normalize('79009694844')).to eq('9009694844')
      expect(described_class.normalize('9009694844')).to eq('9009694844')
    end

    it 'returns nil for invalid inputs' do
      expect(described_class.normalize('123')).to be_nil
      expect(described_class.normalize('')).to be_nil
      expect(described_class.normalize(nil)).to be_nil
    end
  end

  describe '.add! и .blocked?' do
    it 'adds and finds blocked phone' do
      described_class.add!(phone: '+79009694844', reason: 'complaint 22.05.26')
      expect(described_class.blocked?('+79009694844')).to be(true)
      expect(described_class.blocked?('8 900 969-48-44')).to be(true)
      expect(described_class.blocked?('+79008007766')).to be(false)
    end

    it 'rejects empty or invalid input' do
      expect(described_class.blocked?(nil)).to be(false)
      expect(described_class.blocked?('')).to be(false)
      expect(described_class.blocked?('xyz')).to be(false)
    end
  end

  describe 'expires_at logic' do
    it 'is NOT blocked if entry expired' do
      described_class.add!(phone: '+79009694844', reason: 'temporary',
                            expires_at: 1.minute.ago)
      expect(described_class.blocked?('+79009694844')).to be(false)
    end

    it 'is blocked if expires_at is future' do
      described_class.add!(phone: '+79009694844', reason: 'temp',
                            expires_at: 7.days.from_now)
      expect(described_class.blocked?('+79009694844')).to be(true)
    end

    it 'is blocked if expires_at is nil (permanent)' do
      described_class.add!(phone: '+79009694844', reason: 'permanent')
      expect(described_class.blocked?('+79009694844')).to be(true)
    end
  end

  describe 'soft-delete' do
    it 'destroyed entry does not block anymore' do
      e = described_class.add!(phone: '+79009694844', reason: 'oops')
      e.destroy
      expect(described_class.blocked?('+79009694844')).to be(false)
      expect(described_class.unscoped.where(phone_last10: '9009694844').count).to eq(1)
    end

    it 'unique index allows new entry after soft-delete' do
      e = described_class.add!(phone: '+79009694844', reason: 'oops')
      e.destroy
      expect { described_class.add!(phone: '+79009694844', reason: 're-add') }.not_to raise_error
    end
  end

  describe 'validations' do
    it 'requires reason' do
      expect { described_class.create!(phone_last10: '9009694844', added_by: 'admin') }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'requires phone_last10 to be exactly 10 digits' do
      expect { described_class.create!(phone_last10: '123', reason: 'x', added_by: 'admin') }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'requires known added_by source' do
      expect { described_class.create!(phone_last10: '9009694844', reason: 'x', added_by: 'unknown') }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe '#display_phone' do
    it 'formats как +7XXXXXXXXXX' do
      e = described_class.add!(phone: '+79009694844', reason: 'x')
      expect(e.display_phone).to eq('+79009694844')
    end
  end
end
