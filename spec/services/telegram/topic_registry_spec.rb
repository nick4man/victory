# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::TopicRegistry do
  # В test-окружении cache_store = :null_store (config/environments/test.rb),
  # поэтому record_discovery писал в никуда, overrides всегда оставался пустым
  # и побеждало значение из YAML. Подменяем кэш точечно здесь, а не глобально
  # в test.rb: остальные 895 примеров сохраняют прежнюю семантику.
  let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(memory_cache)
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
    # Источник называется site_valuation — так он объявлен в LeadEvent::SOURCES,
    # Lead::Intake::SUPPORTED_SOURCES и в auto_route_from самого YAML.
    # Значения site_valuation_form не существует нигде: спек его выдумал.
    it 'возвращает appraisal для источника site_valuation (из auto_route_from)' do
      expect(described_class.auto_route_for('site_valuation')).to eq('appraisal')
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
    # Спек писался до Phase 0 discovery, когда YAML был без thread_id и все 16
    # ключей числились «недостающими». Сейчас в config/telegram_topics.yml
    # заполнены все 16 message_thread_id, поэтому пустой результат — не баг,
    # а признак того, что discovery доведён до конца.
    it 'пуст, когда в YAML заполнены все message_thread_id' do
      expect(described_class.missing_keys).to be_empty
    end

    # Логику reject-а проверяем на подменённом конфиге, а не на снапшоте YAML:
    # иначе тест снова протухнет при следующей правке конфига.
    it 'возвращает ключи без message_thread_id и убирает их после discovery' do
      allow(described_class).to receive(:config).and_return(
        topics: {
          dispatcher: { tg_title: 'ДИСПЕТЧЕРСКАЯ' },
          apartments: { tg_title: 'КВАРТИРЫ', message_thread_id: 17 }
        }
      )

      expect(described_class.missing_keys).to eq(['dispatcher'])

      described_class.record_discovery('dispatcher', 99)

      expect(described_class.missing_keys).to be_empty
      expect(described_class.thread_id('dispatcher')).to eq(99)
    end
  end
end
