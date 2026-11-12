# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::QualifyLead do
  describe 'тест-режим (issue #214)' do
    after { Thread.current[:lead_test_mode] = false }

    it 'probe-прогон: Inquiry создаётся с metadata["test"]=true' do
      Thread.current[:lead_test_mode] = true

      result = described_class.call(
        intent: 'buy', name: 'Пробный Тест', phone: '+79001112233',
        budget_rub: 8_000_000, district: 'Центр', timeline: 'сейчас'
      )

      inquiry = Inquiry.find(result[:inquiry_id])
      expect(inquiry.metadata['test']).to be(true)
      expect(inquiry).to be_test
      expect(inquiry.source).to eq('site_chatbot')
    end

    it 'боевой прогон: тест-флага в metadata нет' do
      Thread.current[:lead_test_mode] = false

      result = described_class.call(
        intent: 'buy', name: 'Реальный Клиент', phone: '+79004445566',
        budget_rub: 8_000_000
      )

      inquiry = Inquiry.find(result[:inquiry_id])
      expect(inquiry.metadata).not_to have_key('test')
      expect(inquiry).not_to be_test
    end

    it 'без phone/name Inquiry не создаётся ни в одном режиме' do
      Thread.current[:lead_test_mode] = true
      expect { described_class.call(intent: 'buy') }.not_to change(Inquiry, :count)
    end
  end
end
