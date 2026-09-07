# frozen_string_literal: true

require 'rails_helper'

# Task 7 — экран очереди расхождений. Только читает: разрешение конфликта
# (кнопка «принять значение») сюда не входит, редактор правит карточку ЖК
# руками через ссылку с этого экрана.
RSpec.describe 'Admin::ZhkDiscrepancies', type: :request do
  include_context 'с админ-токеном'

  describe 'доступ' do
    it 'без токена не пускает' do
      get admin_zhk_discrepancies_path

      expect(response).to have_http_status(:found)
    end
  end

  describe 'пустая очередь' do
    it 'отдаёт 200 с человеческим текстом о том, что расхождений нет' do
      admin_get admin_zhk_discrepancies_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Расхождений нет')
    end
  end

  describe 'спорное поле' do
    let!(:complex) { create(:residential_complex, name: 'Скобелев') }

    before do
      ZhkFact.create!(residential_complex: complex, field: 'developer', value: 'Единство',
                       source: 'erz', url: 'https://erz.ru/skobelev', observed_at: Time.zone.local(2026, 9, 1))
      ZhkFact.create!(residential_complex: complex, field: 'developer', value: 'Северная компания',
                       source: 'developer_site', url: 'https://severnaya.ru', observed_at: Time.zone.local(2026, 9, 3))
    end

    it 'показывает ЖК, поле, оба значения, оба источника и ссылку на карточку' do
      admin_get admin_zhk_discrepancies_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Скобелев')
      expect(response.body).to include('Застройщик')
      expect(response.body).to include('Единство')
      expect(response.body).to include('Северная компания')
      expect(response.body).to include('erz')
      expect(response.body).to include('developer_site')
      expect(response.body).to include(edit_admin_residential_complex_path(complex))
    end

    it 'показывает дату наблюдения в формате dd.MM.yy' do
      admin_get admin_zhk_discrepancies_path

      expect(response.body).to include('01.09.26')
      expect(response.body).to include('03.09.26')
    end
  end

  describe 'недоверенный ввод' do
    let!(:complex) { create(:residential_complex, name: 'Скобелев') }

    before do
      ZhkFact.create!(residential_complex: complex, field: 'developer',
                       value: '<script>alert(1)</script>', source: 'erz', observed_at: Time.current)
      ZhkFact.create!(residential_complex: complex, field: 'developer',
                       value: 'Единство', source: 'developer_site', observed_at: Time.current)
    end

    it 'экранирует значение с HTML-разметкой' do
      admin_get admin_zhk_discrepancies_path

      expect(response.body).not_to include('<script>alert(1)</script>')
      expect(response.body).to include(CGI.escapeHTML('<script>alert(1)</script>'))
    end
  end

  describe 'ссылка на источник с недопустимой схемой' do
    let!(:complex) { create(:residential_complex, name: 'Скобелев') }

    before do
      ZhkFact.create!(residential_complex: complex, field: 'developer', value: 'Единство',
                       source: 'erz', url: 'javascript:alert(document.cookie)', observed_at: Time.current)
      ZhkFact.create!(residential_complex: complex, field: 'developer', value: 'Северная компания',
                       source: 'developer_site', url: 'https://severnaya.ru', observed_at: Time.current)
    end

    it 'не превращает javascript: в рабочий href, но показывает значение текстом' do
      admin_get admin_zhk_discrepancies_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('href="javascript:alert(document.cookie)"')
      expect(response.body).to include('javascript:alert(document.cookie)')
    end

    it 'сохраняет рабочую ссылку для http(s)-источника рядом' do
      admin_get admin_zhk_discrepancies_path

      expect(response.body).to include('href="https://severnaya.ru"')
    end
  end

  describe 'подпись поля' do
    let!(:complex) { create(:residential_complex, name: 'Скобелев') }

    before do
      ZhkFact.create!(residential_complex: complex, field: 'wall_material', value: 'монолит',
                       source: 'erz', observed_at: Time.current)
      ZhkFact.create!(residential_complex: complex, field: 'wall_material', value: 'кирпич',
                       source: 'developer_site', observed_at: Time.current)
    end

    it 'показывает русскую подпись поля, а не служебное имя колонки' do
      admin_get admin_zhk_discrepancies_path

      expect(response.body).to include('Материал стен')
      expect(response.body).not_to include('поле «wall_material»')
    end
  end
end
