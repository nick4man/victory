# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DocumentIntake::PassportParser do
  subject(:parser) { described_class.new(ocr_text) }

  # ── Test vectors ──────────────────────────────────────────────────────────
  # Реальный формат паспорта РФ — строки из OCR, включая шум.

  let(:full_passport_text) do
    <<~TEXT
      РОССИЙСКАЯ ФЕДЕРАЦИЯ
      ПАСПОРТ
      12 34 567890
      ИВАНОВ
      ИВАН
      ИВАНОВИЧ
      01.02.1985
      Г. МОСКВА
      МЕСТО РОЖДЕНИЯ
      Г. МОСКВА
      ВЫДАН
      ГУ МВД России ПО Г. МОСКВЕ
      01.03.2010
      123-456
    TEXT
  end

  let(:minimal_passport_text) do
    "12 34 567890\nСИДОРОВА\nАННА\nСИДОРОВНА\n15.07.1990"
  end

  describe '.call' do
    it 'delegates to #call' do
      result = described_class.call(minimal_passport_text)
      expect(result).to be_a(Hash)
    end
  end

  describe '#call — full passport' do
    subject(:result) { described_class.call(full_passport_text) }

    it 'extracts passport series' do
      expect(result[:passport_series]).to eq('1234')
    end

    it 'extracts passport number' do
      expect(result[:passport_number]).to eq('567890')
    end

    it 'extracts last name' do
      expect(result[:last_name]).to eq('ИВАНОВ')
    end

    it 'extracts first name' do
      expect(result[:first_name]).to eq('ИВАН')
    end

    it 'extracts middle name' do
      expect(result[:middle_name]).to eq('ИВАНОВИЧ')
    end

    it 'extracts birth_date in ISO format' do
      expect(result[:birth_date]).to eq('1985-02-01')
    end

    it 'extracts issue_code' do
      expect(result[:issue_code]).to eq('123-456')
    end

    it 'sets confidence >= 0.8 when all mandatory fields present' do
      expect(result[:confidence]).to be >= 0.8
    end
  end

  describe '#call — minimal text (only series+number+fio+birthdate)' do
    subject(:result) { described_class.call(minimal_passport_text) }

    it 'extracts series' do
      expect(result[:passport_series]).to eq('1234')
    end

    it 'extracts number' do
      expect(result[:passport_number]).to eq('567890')
    end

    it 'extracts FIO' do
      expect(result[:last_name]).to eq('СИДОРОВА')
      expect(result[:first_name]).to eq('АННА')
    end

    it 'extracts birth_date' do
      expect(result[:birth_date]).to eq('1990-07-15')
    end

    it 'has confidence = 1.0 when all mandatory fields extracted' do
      expect(result[:confidence]).to eq(1.0)
    end
  end

  describe '#call — garbage text' do
    let(:garbage_text) { 'lorem ipsum dolor 12345' }

    subject(:result) { described_class.call(garbage_text) }

    it 'returns nil for all fields' do
      expect(result[:passport_series]).to be_nil
      expect(result[:passport_number]).to be_nil
      expect(result[:last_name]).to be_nil
    end

    it 'sets confidence to 0.0' do
      expect(result[:confidence]).to eq(0.0)
    end
  end

  describe '#call — series/number format variants' do
    {
      '«12 34 567890»'       => %w[1234 567890],
      '«1234 567890»'        => %w[1234 567890],
      '«12  34  567890»'     => %w[1234 567890]
    }.each do |example_text, (exp_series, exp_number)|
      context "text: #{example_text}" do
        it 'parses correctly' do
          result = described_class.call(example_text)
          expect(result[:passport_series]).to eq(exp_series)
          expect(result[:passport_number]).to eq(exp_number)
        end
      end
    end
  end

  describe '#call — date extraction ordering' do
    let(:text_two_dates) do
      "01.01.1990\nИВАНОВ\nИВАН\nИВАНОВИЧ\n\nВЫДАН\nМВД\n15.06.2010\n123-456"
    end

    it 'assigns first date as birth_date and second as issue_date' do
      result = described_class.call(text_two_dates)
      expect(result[:birth_date]).to eq('1990-01-01')
      expect(result[:issue_date]).to eq('2010-06-15')
    end
  end
end
