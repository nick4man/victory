# frozen_string_literal: true

require 'rails_helper'

# A2 Фаза 3 — хаб `/zhk`. Гейт (HUB_MIN_COMPLEXES=3) управляет только
# индексируемостью (noindex,follow), НЕ доступностью страницы: справочник
# на проде сейчас пуст (0 строк), и хаб обязан рендериться штатно —
# с empty-state, а не 404 — до тех пор, пока не наполнится.
RSpec.describe 'ResidentialComplexes (хаб /zhk)', type: :request do
  describe 'GET /zhk — пустой справочник' do
    it 'отдаёт 200 с empty-state и noindex,follow' do
      get '/zhk'

      expect(response).to have_http_status(:ok)
      doc = response.parsed_body
      expect(doc.at_css('meta[name="robots"]')['content']).to eq('noindex,follow')
      expect(response.body).to include('Весь каталог')
    end
  end

  describe 'GET /zhk — есть ЖК, но меньше гейта (1-2)' do
    it 'показывает карточки и всё ещё noindex,follow' do
      create(:residential_complex, :with_body, name: 'Легенда')

      get '/zhk'

      doc = response.parsed_body
      expect(response.body).to include('Легенда')
      expect(doc.at_css('meta[name="robots"]')['content']).to eq('noindex,follow')
    end

    it 'не показывает неопубликованные и ЖК без текста' do
      create(:residential_complex, :with_body, name: 'Легенда')
      create(:residential_complex, name: 'Черновик', published: false)
      create(:residential_complex, name: 'Без текста', published: true, body_blocks: [])

      get '/zhk'

      expect(response.body).to include('Легенда')
      expect(response.body).not_to include('Черновик')
      expect(response.body).not_to include('Без текста')
    end
  end

  describe 'GET /zhk — гейт пройден (≥3 готовых ЖК)' do
    it 'без noindex' do
      create_list(:residential_complex, 3, :with_body)

      get '/zhk'

      doc = response.parsed_body
      expect(doc.at_css('meta[name="robots"]')).to be_nil
    end

    it 'ссылки карточек ведут на канонический /zhk/:slug' do
      complex = create(:residential_complex, :with_body, name: 'Легенда')
      create_list(:residential_complex, 2, :with_body)

      get '/zhk'

      expect(response.body).to include("/zhk/#{complex.slug}")
    end
  end
end
