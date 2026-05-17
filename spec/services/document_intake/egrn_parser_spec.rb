# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DocumentIntake::EgrnParser do
  let(:full_egrn_text) do
    <<~TEXT
      ВЫПИСКА ИЗ ЕДИНОГО ГОСУДАРСТВЕННОГО РЕЕСТРА НЕДВИЖИМОСТИ
      об основных характеристиках и зарегистрированных правах на объект недвижимости

      Кадастровый номер: 50:20:0020302:333
      Адрес: Московская обл., г. Жуковский, ул. Гагарина, д. 10, кв. 25
      Площадь: 54,3 кв. м
      Жилая площадь: 32,1 кв. м

      Вид права: Собственность
      Правообладатель: ИВАНОВ ИВАН ИВАНОВИЧ
      Дата регистрации: 15.06.2015

      Ограничения прав и обременения объекта недвижимости
      не зарегистрированы
    TEXT
  end

  describe '.call' do
    it 'returns a Hash' do
      expect(described_class.call(full_egrn_text)).to be_a(Hash)
    end
  end

  describe '#call — full ЕГРН extract' do
    subject(:result) { described_class.call(full_egrn_text) }

    it 'extracts cadastral number' do
      expect(result[:cadastral_number]).to eq('50:20:0020302:333')
    end

    it 'extracts area' do
      expect(result[:area]).to eq('54.3')
    end

    it 'extracts living area' do
      expect(result[:living_area]).to eq('32.1')
    end

    it 'extracts address' do
      expect(result[:address]).to include('Жуковский')
    end

    it 'extracts owner' do
      expect(result[:owner]).to include('ИВАНОВ')
    end

    it 'extracts right_type' do
      expect(result[:right_type]).to eq('Собственность')
    end

    it 'extracts registration_date in ISO format' do
      expect(result[:registration_date]).to eq('2015-06-15')
    end

    it 'returns empty array for encumbrances (none registered)' do
      expect(result[:encumbrances]).to eq([])
    end
  end

  describe '#call — cadastral number variants' do
    [
      '50:20:0020302:333',    # стандартный формат
      '77:01:0001001:1234',   # Москва
      '78:12:0006001:99'      # Петербург — короткий участок
    ].each do |cad|
      it "extracts #{cad}" do
        result = described_class.call("Кадастровый номер #{cad}")
        expect(result[:cadastral_number]).to eq(cad)
      end
    end
  end

  describe '#call — area normalization (comma → dot)' do
    it 'normalises comma decimal separator' do
      result = described_class.call("Площадь 84,7 кв. м")
      expect(result[:area]).to eq('84.7')
    end

    it 'handles integer area' do
      result = described_class.call("Площадь 50 кв.м")
      expect(result[:area]).to eq('50')
    end
  end

  describe '#call — empty text' do
    subject(:result) { described_class.call('') }

    it 'returns nil for all fields' do
      expect(result[:cadastral_number]).to be_nil
      expect(result[:area]).to be_nil
      expect(result[:owner]).to be_nil
    end
  end
end
