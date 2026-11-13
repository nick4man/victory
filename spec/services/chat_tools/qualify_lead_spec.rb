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

    # Находка ревью PR #221: дедуп по телефону смешивал режимы — тест-прогон
    # возвращал боевой Inquiry (тест без карточки) или наоборот (боевой лид с
    # тестовой карточкой и запретом CRM-синка).
    describe 'дедупликация строго внутри своего режима' do
      it 'тест-прогон с телефоном боевого лида создаёт ОТДЕЛЬНЫЙ тестовый inquiry' do
        prod = described_class.call(intent: 'buy', name: 'Реальный Клиент', phone: '+79005554433')

        Thread.current[:lead_test_mode] = true
        test = described_class.call(intent: 'buy', name: 'Пробный Тест', phone: '+79005554433')

        expect(test[:inquiry_id]).not_to eq(prod[:inquiry_id])
        expect(Inquiry.find(test[:inquiry_id])).to be_test
      end

      it 'боевой прогон с телефоном тестового лида создаёт ОТДЕЛЬНЫЙ боевой inquiry' do
        Thread.current[:lead_test_mode] = true
        test = described_class.call(intent: 'buy', name: 'Пробный Тест', phone: '+79006667755')

        Thread.current[:lead_test_mode] = false
        prod = described_class.call(intent: 'buy', name: 'Реальный Клиент', phone: '+79006667755')

        expect(prod[:inquiry_id]).not_to eq(test[:inquiry_id])
        expect(Inquiry.find(prod[:inquiry_id])).not_to be_test
      end

      it 'дедуп внутри одного режима работает (повторный вызов LLM)' do
        Thread.current[:lead_test_mode] = true
        first = described_class.call(intent: 'buy', name: 'Пробный Тест', phone: '+79007778899')
        second = described_class.call(intent: 'buy', name: 'Пробный Тест', phone: '+79007778899')

        expect(second[:inquiry_id]).to eq(first[:inquiry_id])
      end
    end
  end
end
