# frozen_string_literal: true

require 'rails_helper'

# A2 Фаза 3 — один SQL на count/min/max/avg вместо четырёх отдельных
# агрегатных запросов (см. LandingsController#build_scope, пересобирающий
# scope 4× за запрос). Регресс, которого стоит бояться: если шесть
# Arel.sql-аргументов случайно схлопнутся в одну строку с запятыми,
# `pick` тихо вернёт только первую колонку — спека должна это ловить.
RSpec.describe ListingStats do
  describe '.for' do
    context 'непустая подборка' do
      before do
        create(:property, :on_site, price: 5_000_000, area: 50, price_per_sqm: 100_000)
        create(:property, :on_site, price: 7_000_000, area: 70, price_per_sqm: 100_000)
      end

      it 'считает все шесть агрегатов одним вызовом' do
        result = described_class.for(Property.on_site)

        expect(result.count).to eq(2)
        expect(result.min_price.to_i).to eq(5_000_000)
        expect(result.max_price.to_i).to eq(7_000_000)
        expect(result.avg_price_per_sqm.to_i).to eq(100_000)
        expect(result.min_area.to_i).to eq(50)
        expect(result.max_area.to_i).to eq(70)
      end
    end

    context 'пустая подборка' do
      it 'count = 0, остальные агрегаты nil (не 0 и не exception)' do
        result = described_class.for(Property.on_site)

        expect(result.count).to eq(0)
        expect(result.min_price).to be_nil
        expect(result.max_price).to be_nil
        expect(result.avg_price_per_sqm).to be_nil
        expect(result.min_area).to be_nil
        expect(result.max_area).to be_nil
      end
    end

    it 'возвращает Result со всеми шестью полями (а не схлопнутый скаляр)' do
      result = described_class.for(Property.on_site)

      expect(result).to be_a(described_class::Result)
      expect(result.to_h.keys).to match_array(
        %i[count min_price max_price avg_price_per_sqm min_area max_area]
      )
    end
  end
end
