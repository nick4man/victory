# frozen_string_literal: true

require 'rails_helper'

# Phase 4B — /doc command parser. Pure logic — no DB, no side-effects.
# Тестируем 4 axis variations: action suffix (+/-/?), combined leap
# (+verified/+approved), set-action (=approved), reject syntax
# (@reject:reason). Plus alias resolution (RU + EN short forms).
RSpec.describe DocumentChecklist::Tokenizer do
  describe '#parse — action suffixes' do
    it 'parses + → received' do
      result = described_class.new('passport+').parse
      expect(result.tokens).to contain_exactly(
        { kind: 'passport_main', action: :received }
      )
      expect(result.errors).to be_empty
    end

    it 'parses - → not_requested (revert)' do
      result = described_class.new('passport-').parse
      expect(result.tokens.first[:action]).to eq(:not_requested)
    end

    it 'parses ? → requested' do
      result = described_class.new('snils?').parse
      expect(result.tokens.first[:action]).to eq(:requested)
    end
  end

  describe '#parse — combined leap (+verified, +approved)' do
    it 'parses +verified → action=received, also=:verified' do
      result = described_class.new('contract+verified').parse
      expect(result.tokens.first).to include(
        kind: 'contract_sale', action: :received, also: :verified
      )
    end

    it 'parses +approved → action=received, also=:approved' do
      result = described_class.new('inn+approved').parse
      expect(result.tokens.first[:also]).to eq(:approved)
    end
  end

  describe '#parse — set syntax (=)' do
    it 'parses =approved → admin-leap к approved' do
      result = described_class.new('snils=approved').parse
      expect(result.tokens.first[:action]).to eq(:approved)
    end

    it 'parses =verified' do
      result = described_class.new('inn=verified').parse
      expect(result.tokens.first[:action]).to eq(:verified)
    end

    it 'parses =rejected' do
      result = described_class.new('egrn=rejected').parse
      expect(result.tokens.first[:action]).to eq(:rejected)
    end
  end

  describe '#parse — @reject:reason' do
    it 'captures reason in token' do
      result = described_class.new('poa@reject:no_notary').parse
      expect(result.tokens.first).to include(
        kind: 'power_of_attorney', action: :rejected, reason: 'no_notary'
      )
    end

    it 'accepts multi-word reason' do
      result = described_class.new('contract@reject:client_changed_mind').parse
      expect(result.tokens.first[:reason]).to eq('client_changed_mind')
    end
  end

  describe '#parse — aliases (RU + EN)' do
    it 'resolves RU "ипотека" → mortgage_approval' do
      result = described_class.new('ипотека+').parse
      expect(result.tokens.first[:kind]).to eq('mortgage_approval')
    end

    it 'resolves RU "выписка" → egrn_excerpt' do
      result = described_class.new('выписка?').parse
      expect(result.tokens.first[:kind]).to eq('egrn_excerpt')
    end

    it 'resolves EN "pass" → passport_main' do
      result = described_class.new('pass+').parse
      expect(result.tokens.first[:kind]).to eq('passport_main')
    end

    it 'resolves "egrn" → egrn_excerpt' do
      result = described_class.new('egrn?').parse
      expect(result.tokens.first[:kind]).to eq('egrn_excerpt')
    end
  end

  describe '#parse — batch' do
    it 'parses multiple tokens space-separated' do
      result = described_class.new('passport+ snils+ inn?').parse
      expect(result.tokens.size).to eq(3)
      expect(result.tokens.map { |t| t[:kind] }).to eq(%w[passport_main snils inn])
    end

    it 'mixes valid tokens + invalid into separate fields' do
      result = described_class.new('passport+ invalid_token snils?').parse
      expect(result.tokens.size).to eq(2)
      expect(result.errors).to be_present
      expect(result.errors.first).to include('invalid_token')
    end
  end

  describe '#parse — error paths' do
    it 'empty input → no tokens + errors' do
      result = described_class.new('').parse
      expect(result.tokens).to be_empty
      expect(result.errors).to include('пустой ввод')
    end

    it 'unknown kind alias → error' do
      result = described_class.new('nonexistent+').parse
      expect(result.tokens).to be_empty
      expect(result.errors.first).to include('nonexistent')
    end

    it 'malformed token (no action) → error' do
      result = described_class.new('passport').parse
      expect(result.tokens).to be_empty
      expect(result.errors).to be_present
    end
  end

  describe 'Result struct' do
    it '#success? = true when no errors' do
      r = described_class.new('passport+').parse
      expect(r.success?).to be(true)
    end

    it '#success? = false when errors present' do
      r = described_class.new('invalid+').parse
      expect(r.success?).to be(false)
    end
  end
end
