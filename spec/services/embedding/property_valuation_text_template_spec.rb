# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Embedding::PropertyValuationTextTemplate do
  let(:valuation) do
    PropertyValuation.new(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      status: 'completed',
      address: 'г. Рязань, ул. Ленина, д. 10, кв. 5',
      city: 'Рязань', district: 'Октябрьский',
      total_area: 52.5, rooms: 2, floor: 3, total_floors: 9,
      building_year: 2008, property_condition: 'good',
      estimated_price: 5_250_000, min_price: 4_900_000, max_price: 5_600_000,
      evaluation_data: { 'comparables' => [{ 'price' => 1 }, { 'price' => 2 }, { 'price' => 3 }] },
      name: 'Иванова Мария Петровна',
      email: 'maria.ivanova@example.com',
      phone: '+79001234567',
      ip_address: '203.0.113.42',
      updated_at: Time.zone.local(2026, 11, 8, 12, 0)
    )
  end

  describe '.build' do
    subject(:text) { described_class.build(valuation) }

    it 'включает параметры объекта и результат оценки' do
      expect(text).to include('Тип объекта: квартира')
      expect(text).to include('Тип сделки: продажа')
      expect(text).to include('Город: Рязань')
      expect(text).to include('Район: Октябрьский')
      expect(text).to include('52.5 м²')
      expect(text).to include('Комнат: 2')
      expect(text).to include('Этаж: 3 из 9')
      expect(text).to include('Состояние: хорошее')
      expect(text).to include('Год постройки: 2008')
      expect(text).to include('Итоговая цена оценки: 5 250 000 ₽')
      expect(text).to include('Цена за м²: 100 000 ₽')
      expect(text).to include('Использовано аналогов: 3')
    end

    it 'дата оценки в формате dd.MM.yy' do
      expect(text).to include('Дата оценки: 08.11.26')
      expect(text).not_to match(/\d{4}-\d{2}-\d{2}/)
    end

    it 'НЕ содержит персональные данные (ФИО / телефон / email / ip)' do
      aggregate_failures do
        expect(text).not_to include('Иванова')
        expect(text).not_to include('Мария')
        expect(text).not_to include('79001234567')
        expect(text).not_to include('maria.ivanova@example.com')
        expect(text).not_to include('203.0.113.42')
        expect(text).not_to include('Ленина') # адрес идентифицирует человека — тоже исключён
      end
    end

    context 'без estimated_price — вилка min/max' do
      before { valuation.estimated_price = nil }

      it 'показывает вилку вместо итоговой цены и не считает ₽/м²' do
        expect(text).to include('Вилка оценки: 4 900 000 - 5 600 000 ₽')
        expect(text).not_to include('Итоговая цена')
        expect(text).not_to include('Цена за м²')
      end
    end

    context 'число аналогов из candidates_kept (нет comparables)' do
      before { valuation.evaluation_data = { 'candidates_kept' => 7 } }

      it 'берёт candidates_kept' do
        expect(text).to include('Использовано аналогов: 7')
      end
    end
  end
end
