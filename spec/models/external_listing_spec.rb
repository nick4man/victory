# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalListing do
  describe '.normalize_city' do
    it 'снимает префикс «г.» и «город»' do
      expect(described_class.normalize_city('г. Рязань')).to eq('Рязань')
      expect(described_class.normalize_city('г Рязань')).to eq('Рязань')
      expect(described_class.normalize_city('город Рязань')).to eq('Рязань')
      expect(described_class.normalize_city('Г. Рязань')).to eq('Рязань')
    end

    it 'не трогает названия, начинающиеся с «Г»' do
      expect(described_class.normalize_city('Горно-Алтайск')).to eq('Горно-Алтайск')
      expect(described_class.normalize_city('Геленджик')).to eq('Геленджик')
      expect(described_class.normalize_city('Грозный')).to eq('Грозный')
    end

    it 'обрезает пробелы и схлопывает повторные' do
      expect(described_class.normalize_city('  Рязань  ')).to eq('Рязань')
      expect(described_class.normalize_city('Санкт  Петербург')).to eq('Санкт Петербург')
    end

    it 'снимает «г.» и без пробела после точки' do
      expect(described_class.normalize_city('г.Рязань')).to eq('Рязань')
    end
  end

  describe 'нормализация при записи' do
    it 'нормализует city перед валидацией' do
      listing = create(:external_listing, city: 'город Рязань')

      expect(listing.reload.city).to eq('Рязань')
    end

    it 'сохраняет «Горно-Алтайск» без искажений' do
      listing = create(:external_listing, city: 'Горно-Алтайск')

      expect(listing.reload.city).to eq('Горно-Алтайск')
    end
  end
end
