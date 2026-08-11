# frozen_string_literal: true

require 'rails_helper'

# Порядок стратегий продиктован замером данных 09.08.26: geom заполнен у
# 100% объектов, district — у трети. Поэтому радиус первичен, район —
# последний, а «все непривязанные» существует ради того, что у всех
# засеянных ЖК координат пока нет.
RSpec.describe Zhk::AttachmentSuggester do
  let(:complex) { create(:residential_complex, name: 'Скобелев', district_slug: 'dashkovo-pesochnya') }

  describe 'выбор стратегии в режиме auto' do
    it 'радиус — когда есть координаты' do
      complex.update!(latitude: 54.6269, longitude: 39.6916)

      expect(described_class.call(complex).strategy).to eq('radius')
    end

    it 'адресные паттерны — когда координат нет' do
      complex.update!(address_patterns: ['Костычева, 8'])

      expect(described_class.call(complex).strategy).to eq('patterns')
    end

    it 'район — когда нет ни координат, ни паттернов' do
      expect(described_class.call(complex).strategy).to eq('district')
    end

    it 'none — когда нет ни одного сигнала' do
      complex.update!(district_slug: nil)

      result = described_class.call(complex)
      expect(result.strategy).to eq('none')
      expect(result.candidates).to be_empty
      expect(result.notes.join).to include('ни одного сигнала')
    end
  end

  describe 'фильтрация кандидатов' do
    let!(:free)     { create(:property, :on_site, district: 'ДП') }
    let!(:attached) { create(:property, :on_site, district: 'ДП', residential_complex: create(:residential_complex, name: 'Чужой')) }

    it 'по району матчит через алиасы, а не по слагу' do
      # В колонке district лежит алиас «ДП», а не slug «dashkovo-pesochnya».
      expect(described_class.call(complex).candidates).to include(free)
    end

    it 'не предлагает уже привязанные' do
      expect(described_class.call(complex).candidates).not_to include(attached)
    end

    it 'strategy=all отдаёт весь пул непривязанных' do
      other_district = create(:property, :on_site, district: 'Канищево')

      result = described_class.call(complex, strategy: 'all')

      expect(result.candidates).to include(free, other_district)
      expect(result.pool_size).to be >= 2
    end

    it 'поиск по адресу сужает выборку' do
      match = create(:property, :on_site, district: 'ДП', address: 'Рязань, проезд Яблочкова, д. 6')

      result = described_class.call(complex, strategy: 'all', query: 'Яблочкова')

      expect(result.candidates).to contain_exactly(match)
    end
  end

  describe 'устойчивость' do
    it 'не падает на районе вне реестра' do
      complex.update_columns(district_slug: 'nesushchestvuyushchiy')

      expect { described_class.call(complex) }.not_to raise_error
      expect(described_class.call(complex).strategy).to eq('none')
    end

    it 'экранирует джокеры в адресных паттернах' do
      complex.update!(address_patterns: ['%'])
      create(:property, :on_site, address: 'Рязань, ул. Реальная, 1')

      # Голый % как LIKE-джокер вернул бы всё; после sanitize_sql_like он
      # ищет буквальный процент.
      expect(described_class.call(complex, strategy: 'patterns').candidates).to be_empty
    end
  end
end
