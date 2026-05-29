# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Formatters::DateFormat do
  describe '.fmt' do
    it 'форматирует Date в dd.MM.yy' do
      expect(described_class.fmt(Date.new(2026, 5, 13))).to eq('13.05.26')
    end

    it 'форматирует Time в dd.MM.yy' do
      expect(described_class.fmt(Time.utc(2026, 1, 7, 12, 0))).to eq('07.01.26')
    end

    it 'возвращает пустую строку для nil/blank' do
      expect(described_class.fmt(nil)).to eq('')
      expect(described_class.fmt('')).to eq('')
    end

    it 'не падает на мусорной строке' do
      expect(described_class.fmt('not a date')).to eq('')
    end
  end

  describe '.fmt_dt' do
    it 'форматирует datetime в dd.MM.yy HH:MM' do
      expect(described_class.fmt_dt(Time.utc(2026, 5, 13, 14, 32))).to eq('13.05.26 14:32')
    end
  end

  describe '.parse' do
    it 'парсит полную дату 13.05.26' do
      expect(described_class.parse('13.05.26')).to eq(Date.new(2026, 5, 13))
    end

    it 'парсит короткий месяц/день 1.5.27' do
      expect(described_class.parse('1.5.27')).to eq(Date.new(2027, 5, 1))
    end

    it 'парсит 4-значный год 13.05.2026' do
      expect(described_class.parse('13.05.2026')).to eq(Date.new(2026, 5, 13))
    end

    it 'парсит дату без года — подставляет текущий' do
      travel_to Date.new(2026, 11, 1) do
        expect(described_class.parse('15.5')).to eq(Date.new(2026, 5, 15))
      end
    end

    it 'возвращает nil для невалидного ввода' do
      expect(described_class.parse('abc')).to be_nil
      expect(described_class.parse('32.13.26')).to be_nil
      expect(described_class.parse(nil)).to be_nil
    end
  end
end
