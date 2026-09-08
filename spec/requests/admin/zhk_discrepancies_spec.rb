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
                       source: 'edinstvo', url: 'https://severnaya.ru', observed_at: Time.zone.local(2026, 9, 3))
    end

    it 'показывает ЖК, поле, оба значения, оба источника и ссылку на карточку' do
      admin_get admin_zhk_discrepancies_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Скобелев')
      expect(response.body).to include('Застройщик')
      expect(response.body).to include('Единство')
      expect(response.body).to include('Северная компания')
      expect(response.body).to include('erz')
      expect(response.body).to include('edinstvo')
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
                       value: 'Единство', source: 'edinstvo', observed_at: Time.current)
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
                       source: 'edinstvo', url: 'https://severnaya.ru', observed_at: Time.current)
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
                       source: 'edinstvo', observed_at: Time.current)
    end

    it 'показывает русскую подпись поля, а не служебное имя колонки' do
      admin_get admin_zhk_discrepancies_path

      expect(response.body).to include('Материал стен')
      expect(response.body).not_to include('поле «wall_material»')
    end
  end

  describe 'поле вне FIELD_LABELS' do
    # Не гипотетика: `FIELD_LABELS` и `Zhk::FactApplier::FILLABLE` — два
    # независимо поддерживаемых списка. Поле могут убрать из `FILLABLE`
    # при переименовании/деприкейшне, а старые строки `ZhkFact` с этим
    # именем в базе останутся — `Zhk::Discrepancies.all` строит очередь
    # из сырых `ZhkFact` и про `FILLABLE` ничего не знает, так что такая
    # строка на экране появится. Экран не должен на ней падать.
    let!(:complex) { create(:residential_complex, name: 'Скобелев') }

    before do
      ZhkFact.create!(residential_complex: complex, field: 'totally_unknown_field',
                       value: 'А', source: 'erz', observed_at: Time.current)
      ZhkFact.create!(residential_complex: complex, field: 'totally_unknown_field',
                       value: 'Б', source: 'edinstvo', observed_at: Time.current)
    end

    it 'показывает сырое имя поля вместо падения' do
      admin_get admin_zhk_discrepancies_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('totally_unknown_field')
    end
  end

  describe 'осиротевшие факты мягко удалённого ЖК' do
    # `ZhkFact` живёт независимо от карточки: `default_scope`
    # `ResidentialComplex` прячет мягко удалённые, и `residential_complex`
    # у таких фактов отдаёт `nil`. Вьюха зовёт `row[:complex].display_name`
    # — падала ВСЯ страница, а не одна строка. Цикл достижим штатно:
    # мягко удалённый ЖК не матчится, следующий обход заводит дубль,
    # редактор удаляет его снова, осиротевшие факты копятся.
    let!(:live) { create(:residential_complex, name: 'Скобелев') }
    let!(:removed) { create(:residential_complex, :soft_deleted, name: 'Удалённый') }

    before do
      ZhkFact.create!(residential_complex: live, field: 'developer', value: 'Единство',
                       source: 'erz', observed_at: Time.current)
      ZhkFact.create!(residential_complex: live, field: 'developer', value: 'Северная компания',
                       source: 'edinstvo', observed_at: Time.current)
      ZhkFact.create!(residential_complex: removed, field: 'developer', value: 'Атом',
                       source: 'erz', observed_at: Time.current)
      ZhkFact.create!(residential_complex: removed, field: 'developer', value: 'Химик',
                       source: 'edinstvo', observed_at: Time.current)
    end

    it 'не роняет страницу и показывает расхождение по живому ЖК' do
      admin_get admin_zhk_discrepancies_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Скобелев')
      expect(response.body).to include('Северная компания')
    end

    it 'не показывает расхождение по удалённой карточке' do
      admin_get admin_zhk_discrepancies_path

      expect(response.body).not_to include('Химик')
    end
  end
end
