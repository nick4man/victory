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
        # price_per_sqm не передаём: Property#calculate_price_per_sqm
        # (before_save) считает его сам из price/area. Цифры подобраны так,
        # что обе записи дают ровно 100 000 ₽/м².
        create(:property, :on_site, price: 5_000_000, area: 50)
        create(:property, :on_site, price: 7_000_000, area: 70)
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

    # Именно этот пример сторожит регресс из шапки файла. Проверять
    # `result.to_h.keys` бесполезно: ключи берутся из определения Struct,
    # а не из SQL, и остались бы на месте, даже если бы `pick` вернул один
    # скаляр. Единственное доказательство, что колонок действительно шесть, —
    # шесть РАЗНЫХ непустых значений, пришедших из базы.
    it 'достаёт шесть отдельных колонок, а не первую из схлопнутой строки' do
      create(:property, :on_site, price: 5_000_000, area: 50)
      create(:property, :on_site, price: 7_000_000, area: 70)

      result = described_class.for(Property.on_site)

      expect(result).to be_a(described_class::Result)
      expect(result.to_h.values).to all(be_present)
      expect(result.max_price).to be > result.min_price
      expect(result.max_area).to be > result.min_area
    end
  end
end
