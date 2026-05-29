# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PropertyRoomsParser do
  describe '.parse' do
    context 'word-forms' do
      it 'extracts студия → 0' do
        expect(described_class.parse('Продаётся стильная студия в центре')).to eq(0)
      end

      it 'extracts свободная планировка → 0' do
        expect(described_class.parse('Квартира со свободной планировкой')).to eq(0)
      end

      it 'extracts однокомнатная → 1' do
        expect(described_class.parse('Уютная однокомнатная квартира в новом доме')).to eq(1)
      end

      it 'extracts двухкомнатная → 2' do
        expect(described_class.parse('Светлая двухкомнатная квартира')).to eq(2)
      end

      it 'extracts трёхкомнатная (с буквой ё) → 3' do
        expect(described_class.parse('Просторная трёхкомнатная квартира')).to eq(3)
      end

      it 'extracts трехкомнатная (без ё) → 3' do
        expect(described_class.parse('Большая трехкомнатная квартира')).to eq(3)
      end

      it 'extracts четырёхкомнатная → 4' do
        expect(described_class.parse('Шикарная четырёхкомнатная квартира')).to eq(4)
      end
    end

    context 'numeric patterns' do
      it 'extracts «3-комн» → 3' do
        expect(described_class.parse('Продаётся 3-комн. квартира')).to eq(3)
      end

      it 'extracts «2 комн» → 2' do
        expect(described_class.parse('Лот: 2 комн., 54 м²')).to eq(2)
      end

      it 'extracts «5 комнат» → 5' do
        expect(described_class.parse('Квартира 5 комнат')).to eq(5)
      end

      it 'extracts «4-к» → 4' do
        expect(described_class.parse('4-к квартира')).to eq(4)
      end
    end

    context 'edge cases' do
      it 'returns nil for blank input' do
        expect(described_class.parse(nil)).to be_nil
        expect(described_class.parse('')).to be_nil
        expect(described_class.parse('   ')).to be_nil
      end

      it 'returns nil когда rooms count не упоминается' do
        expect(described_class.parse('Большой участок 10 соток')).to be_nil
      end

      it 'не ловит false-positive «д. 23» (адрес)' do
        expect(described_class.parse('ул. Ленина, д. 23, кв. 5')).to be_nil
      end

      it 'не ловит «5-литровая» (false-positive substring)' do
        expect(described_class.parse('Бак на 5 литров')).to be_nil
      end

      it 'caps на 6 — игнорирует «10-комн» (вероятно ошибка)' do
        expect(described_class.parse('10-комнатное общежитие')).to be_nil
      end
    end

    context 'priority order' do
      it 'word-form побеждает numeric если оба в тексте' do
        expect(described_class.parse('Однокомнатная квартира, ул. Ленина, д. 3')).to eq(1)
      end
    end
  end
end
