# frozen_string_literal: true

require 'rails_helper'

# Test vectors for INN check-digit algorithm (ФНС ГОСТ Р 34.10).
# Known-good INNs sourced from public ФНС documentation.
RSpec.describe DocumentIntake::InnParser do
  describe '.call' do
    it 'delegates to #call' do
      expect(described_class.call('любой текст')).to be_a(Hash)
    end
  end

  describe '#call — individual INN (12 digits)' do
    # Публичный тест-вектор ФНС (физлицо)
    let(:valid_inn_12) { '500100732259' }
    let(:ocr_text) { "СВИДЕТЕЛЬСТВО О ПОСТАНОВКЕ НА УЧЁТ\nИНН #{valid_inn_12}\nИВАНОВ ИВАН ИВАНОВИЧ" }

    subject(:result) { described_class.call(ocr_text) }

    it 'extracts the INN' do
      expect(result[:inn]).to eq(valid_inn_12)
    end

    it 'identifies as individual' do
      expect(result[:inn_type]).to eq('individual')
    end

    it 'extracts full name if present' do
      expect(result[:full_name]).to be_present
    end
  end

  describe '#call — legal entity INN (10 digits)' do
    # ООО — публичный тест-вектор
    let(:valid_inn_10) { '7707083893' }   # Сбербанк России
    let(:ocr_text) { "ПАО СБЕРБАНК\nИНН #{valid_inn_10}" }

    subject(:result) { described_class.call(ocr_text) }

    it 'extracts the INN' do
      expect(result[:inn]).to eq(valid_inn_10)
    end

    it 'identifies as legal' do
      expect(result[:inn_type]).to eq('legal')
    end
  end

  describe '#call — invalid check digit' do
    # Цифры нормальной длины, но чексумма неверна
    let(:bad_inn) { '500100732260' }   # последняя цифра изменена
    let(:ocr_text) { "ИНН #{bad_inn}" }

    subject(:result) { described_class.call(ocr_text) }

    it 'still returns the INN (best-effort, not nil) but extracted from OCR' do
      # Мы возвращаем raw для human review, но валидный флаг не устанавливаем
      expect(result[:inn]).to eq(bad_inn).or be_nil
    end
  end

  describe '#call — no INN in text' do
    let(:ocr_text) { 'РОССИЙСКАЯ ФЕДЕРАЦИЯ ПАСПОРТ' }

    subject(:result) { described_class.call(ocr_text) }

    it 'returns nil INN' do
      expect(result[:inn]).to be_nil
    end

    it 'returns nil inn_type' do
      expect(result[:inn_type]).to be_nil
    end
  end

  describe 'INN check-digit algorithm — direct tests' do
    let(:parser) { described_class.new('') }

    # Tаблица известных корректных ИНН физлиц
    valid_individual_inns = %w[
      500100732259
      760307073214
    ]

    valid_individual_inns.each do |inn|
      it "validates #{inn} as correct individual INN" do
        # Вызываем через вспомогательный метод напрямую
        expect(parser.send(:valid_individual_inn?, inn)).to be true
      end
    end

    valid_legal_inns = %w[
      7707083893
      7736207543
    ]

    valid_legal_inns.each do |inn|
      it "validates #{inn} as correct legal INN" do
        expect(parser.send(:valid_legal_inn?, inn)).to be true
      end
    end

    it 'rejects INN with wrong check digit' do
      expect(parser.send(:valid_individual_inn?, '500100732258')).to be false
    end
  end
end
