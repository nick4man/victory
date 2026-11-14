# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::RunInvestmentAudit do
  let(:property) { create(:property) }

  before do
    allow(AuditEngine::Client).to receive(:new).and_return(double(health: true))
    allow(Geocoding::AddressLookup).to receive(:call).and_return(nil)
  end

  after { Thread.current[:lead_test_mode] = false }

  describe 'тест-режим чат-бота (issue #214)' do
    it 'probe-прогон: valuation создаётся с metadata["test"]=true' do
      Thread.current[:lead_test_mode] = true

      result = described_class.call(property_slug: property.slug)

      expect(result[:status]).to eq('queued')
      expect(PropertyValuation.find_by(token: result[:token]).metadata['test']).to be(true)
    end

    it 'боевой прогон: тест-флага в metadata нет' do
      result = described_class.call(property_slug: property.slug)

      expect(PropertyValuation.find_by(token: result[:token]).metadata).not_to have_key('test')
    end
  end
end
