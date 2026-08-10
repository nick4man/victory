# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Crm::ContactParser do
  describe '.from_telegram' do
    it 'разбирает пересланную карточку контакта' do
      result = described_class.from_telegram(
        'phone_number' => '79001234567', 'first_name' => 'Светлана', 'last_name' => 'Петрова'
      )

      expect(result).to include(first_name: 'Светлана', last_name: 'Петрова', phone: '79001234567')
    end

    it 'не принимает карточку без номера' do
      expect(described_class.from_telegram('first_name' => 'Без номера')).to be_nil
      expect(described_class.from_telegram(nil)).to be_nil
    end
  end

  describe '.from_text' do
    # Агент пишет как придётся — требовать строгий формат значит получить ноль
    # ответов. Проверяем те виды, которые реально встречаются в переписке.
    it 'разбирает имя и телефон без разделителей' do
      result = described_class.from_text('Светлана 9001234567')
      expect(result[:first_name]).to eq('Светлана')
      expect(result[:phone].gsub(/\D/, '')).to eq('9001234567')
    end

    it 'разбирает телефон в бытовом виде со скобками' do
      result = described_class.from_text('Пётр Иванов +7 (900) 123-45-67')
      expect(result[:first_name]).to eq('Пётр')
      expect(result[:last_name]).to eq('Иванов')
      expect(result[:phone].gsub(/\D/, '')).to eq('79001234567')
    end

    it 'выкидывает служебные слова из имени' do
      result = described_class.from_text('собственник — Пётр Иванович, тел 8 900 123 45 67')
      expect(result[:first_name]).to eq('Пётр')
      expect(result[:last_name]).to eq('Иванович')
    end

    it 'берёт email' do
      result = described_class.from_text('Мария mari@example.ru')
      expect(result[:email]).to eq('mari@example.ru')
      expect(result[:first_name]).to eq('Мария')
    end

    it 'работает, когда есть только email без имени' do
      result = described_class.from_text('owner@example.ru')
      expect(result[:email]).to eq('owner@example.ru')
      expect(result[:phone]).to be_nil
    end

    # Без телефона и почты клиента заводить не из чего — лучше переспросить,
    # чем создать пустую учётку, которую потом никто не опознает.
    it 'возвращает nil, когда контакта в тексте нет' do
      expect(described_class.from_text('не помню, посмотрю позже')).to be_nil
      expect(described_class.from_text('')).to be_nil
      expect(described_class.from_text(nil)).to be_nil
    end

    # Номер дома и площадь не должны превращаться в телефон.
    it 'не принимает короткие числа за номер' do
      expect(described_class.from_text('квартира 54 дом 12')).to be_nil
    end
  end
end
