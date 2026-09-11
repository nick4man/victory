# frozen_string_literal: true

require 'rails_helper'

# /sitemap-pages.xml в части ЖК (A2 Фаза 3).
#
# Спека появилась по итогам ревью PR #37: хаб `/zhk` выводился в sitemap
# безусловно, а сама страница при незакрытом гейте отдавала `noindex,follow` —
# ровно то расхождение sitemap ↔ robots, за которое Яндекс демотирует.
# Примеры `zhk_hub_spec` проверяли noindex, но ни один не спрашивал, что в
# этот момент говорит sitemap, поэтому блокер и дожил до ревью. Теперь оба
# потребителя ходят в один предикат (`ResidentialComplex.hub_indexable?`), и
# проверяем мы именно согласованность, а не каждую сторону по отдельности.
RSpec.describe 'Sitemap', type: :request do
  # У XML-ответа `parsed_body` отдаёт Hash::from_xml, где единственный <url>
  # схлопывается в хеш, а не в массив — по нему не проверишь ни отсутствие,
  # ни порядок. Поэтому здесь Nokogiri (у HTML-ответа `parsed_body` и так
  # Nokogiri, там он и используется).
  def sitemap_locs
    get '/sitemap-pages.xml'
    expect(response).to have_http_status(:ok)
    Nokogiri::XML(response.body).remove_namespaces!.xpath('//url/loc').map(&:text)
  end

  def hub_noindex?
    get '/zhk'
    expect(response).to have_http_status(:ok)
    response.parsed_body.at_css('meta[name="robots"]')&.[]('content') == 'noindex,follow'
  end

  describe 'хаб /zhk' do
    it 'не попадает в sitemap, пока гейт закрыт (справочник пуст)' do
      expect(sitemap_locs).not_to include(a_string_ending_with('/zhk'))
      expect(hub_noindex?).to be(true)
    end

    it 'не попадает в sitemap, пока готовых ЖК меньше порога' do
      create_list(:residential_complex, ResidentialComplex::HUB_MIN_COMPLEXES - 1, :with_body)

      expect(sitemap_locs).not_to include(a_string_ending_with('/zhk'))
      expect(hub_noindex?).to be(true)
    end

    it 'попадает в sitemap, когда гейт открыт' do
      create_list(:residential_complex, ResidentialComplex::HUB_MIN_COMPLEXES, :with_body)

      expect(sitemap_locs).to include(a_string_ending_with('/zhk'))
      expect(hub_noindex?).to be(false)
    end
  end

  describe 'карточки /zhk/:slug' do
    it 'ЖК без редакционного текста в sitemap не попадает' do
      silent = create(:residential_complex, :published, name: 'Без текста', body_blocks: [])
      loud   = create(:residential_complex, :with_body, name: 'Легенда')

      locs = sitemap_locs
      expect(locs).to include(a_string_ending_with("/zhk/#{loud.slug}"))
      expect(locs).not_to include(a_string_ending_with("/zhk/#{silent.slug}"))
    end

    it 'неопубликованный ЖК в sitemap не попадает' do
      draft = create(:residential_complex, name: 'Черновик', published: false)

      expect(sitemap_locs).not_to include(a_string_ending_with("/zhk/#{draft.slug}"))
    end

    it 'мягко удалённый ЖК в sitemap не попадает' do
      gone = create(:residential_complex, :with_body, name: 'Снесённый')
      gone.soft_delete!

      expect(sitemap_locs).not_to include(a_string_ending_with("/zhk/#{gone.slug}"))
    end
  end

  # Главное, ради чего спека и написана: одна выборка на хаб и sitemap.
  # Раньше контроллер фильтровал по Рязани, а sitemap брал все города — и
  # московский ЖК с текстом уезжал в sitemap индексируемым при нуле входящих
  # ссылок (хаб под рязанским H1 его не перечисляет).
  describe 'ЖК другого города' do
    it 'ведёт себя согласованно с хабом: нет на хабе — нет и в sitemap' do
      moscow = create(:residential_complex, :with_body, name: 'Столичный',
                                                        city: 'Москва', district_slug: nil)
      create_list(:residential_complex, ResidentialComplex::HUB_MIN_COMPLEXES, :with_body)

      get '/zhk'
      expect(response.body).not_to include('Столичный')

      expect(sitemap_locs).not_to include(a_string_ending_with("/zhk/#{moscow.slug}"))
    end

    it 'не засчитывается в гейт хаба' do
      create(:residential_complex, :with_body, city: 'Москва', district_slug: nil)
      create_list(:residential_complex, ResidentialComplex::HUB_MIN_COMPLEXES - 1, :with_body)

      expect(hub_noindex?).to be(true)
      expect(sitemap_locs).not_to include(a_string_ending_with('/zhk'))
    end
  end
end
