# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TelegramGroupMessage do
  let(:base_attrs) do
    {
      tg_chat_id: -1_003_779_115_845,
      tg_message_id: 1001,
      tg_thread_id: 17,
      tg_user_id: 1_272_500_574,
      sender_username: 'oks07victory',
      sender_first_name: 'Оксана',
      payload_kind: 'text',
      has_attachment: false,
      sent_at: Time.current
    }
  end

  describe 'validations + uniqueness' do
    it 'допускает create с базовыми атрибутами' do
      msg = described_class.create!(base_attrs.merge(body: 'привет коллеги'))
      expect(msg).to be_persisted
    end

    it 'отказывает в дубле (chat_id + message_id)' do
      described_class.create!(base_attrs.merge(body: 'first'))
      # Сообщение зависит от config.i18n.default_locale (en: "has already been taken",
      # ru: "уже занято"). Проверяем по errors.details (machine-readable) — locale-neutral.
      expect {
        described_class.create!(base_attrs.merge(body: 'duplicate'))
      }.to raise_error(ActiveRecord::RecordInvalid) { |e|
        # details теперь несут ещё и :value ({error: :taken, value: 1001}),
        # поэтому точное совпадение хэша больше не проходит — проверяем вхождение.
        expect(e.record.errors.details[:tg_message_id]).to include(hash_including(error: :taken))
      }
    end
  end

  describe '.fts (PostgreSQL russian tsvector)' do
    before do
      described_class.create!(base_attrs.merge(tg_message_id: 1, body: 'Канищево квартира 3-комн'))
      described_class.create!(base_attrs.merge(tg_message_id: 2, body: 'Солотча дом с участком'))
      described_class.create!(base_attrs.merge(tg_message_id: 3, body: 'Звонок клиенту Анне завтра'))
    end

    it 'находит точное совпадение' do
      results = described_class.fts('Канищево').to_a
      expect(results.size).to eq(1)
      expect(results.first.body).to include('Канищево')
    end

    it 'учитывает русскую морфологию (клиенту = клиент)' do
      results = described_class.fts('клиент').to_a
      expect(results.size).to eq(1)
      expect(results.first.body).to include('клиенту')
    end

    it 'пустой query → none' do
      expect(described_class.fts('').count).to eq(0)
      expect(described_class.fts(nil).count).to eq(0)
    end
  end

  describe 'scopes' do
    before do
      described_class.create!(base_attrs.merge(tg_message_id: 10, body: 'A', tg_user_id: 100, sender_username: 'alice', tg_thread_id: 17))
      described_class.create!(base_attrs.merge(tg_message_id: 11, body: 'B', tg_user_id: 200, sender_username: 'bob', tg_thread_id: 18))
    end

    it 'by_sender по username (case-insensitive)' do
      expect(described_class.by_sender('alice').count).to eq(1)
      expect(described_class.by_sender('ALICE').count).to eq(1)
    end

    it 'by_sender по tg_user_id integer' do
      expect(described_class.by_sender(200).count).to eq(1)
    end

    it 'in_thread' do
      expect(described_class.in_thread(17).count).to eq(1)
      expect(described_class.in_thread(99).count).to eq(0)
    end
  end

  describe '#tg_link' do
    it 'возвращает t.me ссылку с thread_id для forum топика' do
      msg = described_class.new(base_attrs.merge(tg_message_id: 1000, tg_thread_id: 17))
      expect(msg.tg_link).to eq('https://t.me/c/3779115845/17/1000')
    end

    it 'без thread_id — короткая ссылка' do
      msg = described_class.new(base_attrs.merge(tg_message_id: 1000, tg_thread_id: nil))
      expect(msg.tg_link).to eq('https://t.me/c/3779115845/1000')
    end
  end

  describe '#sender_label' do
    it 'предпочитает @username' do
      msg = described_class.new(base_attrs.merge(sender_username: 'oksana', sender_first_name: 'Оксана'))
      expect(msg.sender_label).to eq('@oksana')
    end

    it 'fallback на first_name если нет username' do
      msg = described_class.new(base_attrs.merge(sender_username: nil, sender_first_name: 'Надежда'))
      expect(msg.sender_label).to eq('Надежда')
    end

    it 'последний fallback на tg:<id>' do
      msg = described_class.new(base_attrs.merge(sender_username: nil, sender_first_name: nil, tg_user_id: 9999))
      expect(msg.sender_label).to eq('tg:9999')
    end
  end
end
