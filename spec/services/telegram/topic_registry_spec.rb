# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::TopicRegistry do
  before do
    described_class.reload!
    Rails.cache.clear
  end

  describe '.chat_id' do
    it 'возвращает chat_id рабочей группы из YAML' do
      expect(described_class.chat_id).to eq(-1_003_779_115_845)
    end
  end

  describe '.all_keys' do
    it 'возвращает все 16 ключей топиков' do
      keys = described_class.all_keys
      expect(keys.size).to eq(16)
      expect(keys).to include('dispatcher', 'apartments', 'mortgage', 'deal', 'qna', 'flood')
    end
  end

  describe '.anchor_keys' do
    it 'возвращает только специализированные якорные топики (role=anchor)' do
      anchor = described_class.anchor_keys
      expect(anchor).to include('apartments', 'houses', 'mortgage', 'appraisal')
      expect(anchor).not_to include('dispatcher', 'deal', 'qna', 'flood', 'announcements')
    end
  end

  describe '.key_by_title' do
    it 'находит ключ по точному русскому названию' do
      expect(described_class.key_by_title('КВАРТИРЫ')).to eq('apartments')
      expect(described_class.key_by_title('ОЦЕНКА')).to eq('appraisal')
    end

    it 'нечувствителен к регистру и пробелам' do
      expect(described_class.key_by_title('  квартиры  ')).to eq('apartments')
    end

    it 'возвращает nil для неизвестного названия' do
      expect(described_class.key_by_title('Чужой топик')).to be_nil
    end
  end

  describe '.auto_route_for' do
    it 'возвращает appraisal для источника site_valuation_form (из auto_route_from)' do
      expect(described_class.auto_route_for('site_valuation_form')).to eq('appraisal')
    end

    it 'возвращает nil для источника без авто-маршрута' do
      expect(described_class.auto_route_for('manual')).to be_nil
    end
  end

  describe '.record_discovery' do
    it 'сохраняет thread_id в кэше для валидного ключа' do
      expect(described_class.record_discovery('apartments', 42)).to be(true)
      expect(described_class.thread_id('apartments')).to eq(42)
    end

    it 'отклоняет невалидный ключ' do
      expect(described_class.record_discovery('foobar', 42)).to be(false)
    end

    it 'отклоняет blank thread_id' do
      expect(described_class.record_discovery('apartments', nil)).to be(false)
    end
  end

  describe '.missing_keys' do
    it 'возвращает все ключи когда ничего не discovered' do
      expect(described_class.missing_keys.size).to eq(16)
    end

    it 'исключает discovered ключи' do
      described_class.record_discovery('dispatcher', 1)
      described_class.record_discovery('apartments', 2)
      expect(described_class.missing_keys).not_to include('dispatcher', 'apartments')
      expect(described_class.missing_keys.size).to eq(14)
    end
  end
end
