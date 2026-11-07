# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20261107233000_add_city_to_external_listings')

RSpec.describe AddCityToExternalListings do
  # YrlParser кладёт raw_payload.internal_id; Tavily websearch под тем же
  # source='yandex_yrl' хранит parsed-карточку без internal_id — бэкфилл
  # должен отличать их, иначе чужие города получили бы «Рязань» (issue #172).
  it 'бэкфиллит city только для записей YrlParser, а не websearch yandex_yrl' do
    yrl_record = create(:external_listing, :yandex_yrl, city: nil,
                        raw_payload: { internal_id: 'yrl-1', last_modified: '2026-01-01' })
    websearch_record = create(:external_listing, :yandex_yrl, city: nil,
                              raw_payload: { source_url: 'https://realty.yandex.ru/offer/42' })
    sitemap_record = create(:external_listing, :agency_sitemap, city: nil)

    described_class.migrate(:down)
    described_class.migrate(:up)

    expect(yrl_record.reload.city).to eq('Рязань')
    expect(sitemap_record.reload.city).to eq('Рязань')
    expect(websearch_record.reload.city).to be_nil
  end
end
