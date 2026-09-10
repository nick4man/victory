# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# A2 Фаза 3 — публичная страница ЖК `/zhk/:slug`.
#
# Основной риск здесь — soft-404: контроллер обязан отдавать настоящий
# HTTP 404 на неизвестный slug (не редирект дефолтного `record_not_found`,
# не 200 с «не найдено» внутри), а noindex-guard обязан отличать «страницы
# нет» (404) от «страница есть, но временно без инвентаря» (200 + noindex).
RSpec.describe 'ResidentialComplexes (публичная страница ЖК)', type: :request do
  describe 'GET /zhk/:slug — неизвестный slug' do
    it 'отдаёт настоящий 404, не редирект и не soft-200' do
      get '/zhk/nesushchestvuyushchiy'

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('СТРАНИЦА НЕ НАЙДЕНА')
    end
  end

  describe 'GET /zhk/:slug — неопубликованный ЖК' do
    it 'отдаёт 404 (черновик не должен быть публично доступен)' do
      draft = create(:residential_complex, :with_body, published: false)

      get "/zhk/#{draft.slug}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /zhk/:slug — опубликованный ЖК с текстом и объектами' do
    let!(:complex) { create(:residential_complex, :with_body, name: 'Легенда') }

    before { create_list(:property, 2, :on_site, residential_complex: complex) }

    it 'отдаёт 200 с одним H1 и без noindex' do
      get "/zhk/#{complex.slug}"

      expect(response).to have_http_status(:ok)
      doc = response.parsed_body
      expect(doc.css('h1').size).to eq(1)
      expect(doc.css('h1').text).to include('Легенда')
      expect(doc.at_css('meta[name="robots"][content*="noindex"]')).to be_nil
    end

    it 'canonical без query-string' do
      get "/zhk/#{complex.slug}?utm_source=test"

      doc = response.parsed_body
      canonical = doc.at_css('link[rel="canonical"]')['href']
      expect(canonical).not_to include('utm_source')
      expect(canonical).to end_with("/zhk/#{complex.slug}")
    end

    # Кэш приватный, а не public: карточка объекта рендерит favorite-toggle
    # для залогиненного клиента кабинета, а layout отдаёт per-session
    # CSRF-токен. Общий кэш вправе был бы отдать страницу одного
    # посетителя другому. Сегодня в тракте нет кэширующего прокси, но
    # закладываться на это — значит поставить дыру на таймер.
    it 'кэшируется приватно, а не в общем кэше' do
      get "/zhk/#{complex.slug}"

      expect(response.headers['Cache-Control']).to include('max-age=900')
      expect(response.headers['Cache-Control']).not_to include('public')
    end

    it 'содержит ApartmentComplex и BreadcrumbList в @graph' do
      get "/zhk/#{complex.slug}"

      graph_script = response.parsed_body.css('script[type="application/ld+json"]').map(&:text)
                             .map { |t| JSON.parse(t) }
                             .find { |json| json['@graph'].present? }
      types = graph_script['@graph'].map { |node| node['@type'] }
      expect(types).to include('ApartmentComplex', 'BreadcrumbList', 'CollectionPage')
    end

    it 'ровно один fetchpriority="high" в разметке (грид без hero-фото)' do
      get "/zhk/#{complex.slug}"

      expect(response.body.scan('fetchpriority="high"').size).to eq(1)
    end

    # `_property_card` показывает риэлтора с телефоном, то есть дёргает
    # `property.user` на каждой карточке. Без `includes(:user)` в
    # `listings_scope` это до 48 запросов к users на страницу. Считаем
    # именно обращения к users, а не общий порог: порог переживает
    # снятие прелоада на малой выборке, а этот счётчик — нет.
    it 'не ходит в users на каждую карточку (прелоад риэлтора)' do
      # У каждого объекта свой агент (фабрика создаёт user на объект),
      # иначе прелоад и его отсутствие дали бы одинаковую цифру.
      create_list(:property, 3, :on_site, residential_complex: complex)

      agents_hit = 0
      counter = lambda do |_n, _s, _f, _i, payload|
        next if payload[:name] == 'SCHEMA'

        agents_hit += 1 if payload[:sql]&.match?(/FROM\s+"users"/)
      end

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        get "/zhk/#{complex.slug}"
      end

      expect(response).to have_http_status(:ok)
      # 5 карточек, у каждой свой агент => один WHERE id IN (...) прелоада.
      # Без includes(:user) здесь было бы пять запросов, по одному на карточку.
      expect(agents_hit).to be <= 1
    end
  end

  describe 'GET /zhk/:slug — опубликованный ЖК без текста и без объектов' do
    it 'noindex,follow присутствует и статус остаётся 200 (не soft-404 в смысле шаблона ошибки)' do
      empty_complex = create(:residential_complex, published: true, body_blocks: [])

      get "/zhk/#{empty_complex.slug}"

      expect(response).to have_http_status(:ok)
      doc = response.parsed_body
      expect(doc.at_css('meta[name="robots"]')['content']).to eq('noindex,follow')
    end
  end

  describe 'GET /zhk/:slug — опубликованный ЖК без текста, но с объектами' do
    it 'indexable? => объекты есть => без noindex' do
      complex = create(:residential_complex, published: true, body_blocks: [])
      create(:property, :on_site, residential_complex: complex)

      get "/zhk/#{complex.slug}"

      doc = response.parsed_body
      expect(doc.at_css('meta[name="robots"][content*="noindex"]')).to be_nil
    end
  end

  describe 'GET /zhk/:slug — мягко удалённый ЖК' do
    # Правило #1 CLAUDE.md. `visible` не дублирует `not_deleted` и целиком
    # полагается на default_scope — если его когда-нибудь снимут, удалённый
    # ЖК начнёт отдавать 200, и заметить это будет некому.
    it 'отдаёт 404, а не страницу удалённого ЖК' do
      complex = create(:residential_complex, :with_body)
      complex.soft_delete!

      get "/zhk/#{complex.slug}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /zhk/:slug — исторический слаг' do
    it 'резолвится через friendly_id history и 301-редиректит на канонический' do
      complex = create(:residential_complex, :with_body)
      old_slug = complex.slug
      complex.update!(slug: 'novoe-imya')

      get "/zhk/#{old_slug}"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers['Location']).to end_with('/zhk/novoe-imya')
    end

    # 301 и 404 кэшировать нельзя: редактор публикует ЖК и ещё четверть
    # часа получал бы по своей же ссылке «страница не найдена».
    it 'не кэширует редирект' do
      complex = create(:residential_complex, :with_body)
      old_slug = complex.slug
      complex.update!(slug: 'drugoe-imya')

      get "/zhk/#{old_slug}"

      expect(response.headers['Cache-Control']).not_to include('max-age=900')
    end
  end

  # Размеры og:image — не косметика: VK/Telegram резервируют кроп по
  # объявленным числам ДО загрузки файла. Ветки precedence объявляют РАЗНЫЕ
  # размеры (брендовый og.jpg — 1200×630, hero-вариант листинга — 1920×1440),
  # и до этих спеков ветка листинга молча донашивала дефолт layout.
  describe 'GET /zhk/:slug — OG-разметка' do
    let!(:complex) { create(:residential_complex, :with_body, name: 'Легенда') }

    def og(doc, prop)
      doc.at_css(%(meta[property="og:image:#{prop}"]))&.[]('content')
    end

    context 'без брендового og.jpg, но с объектами (сегодня основной путь)' do
      let!(:listing) { create(:property, :on_site, residential_complex: complex) }

      it 'берёт картинку первого листинга и объявляет фактические размеры варианта' do
        # Портрет: resize_to_limit [1920, 1440] упирается в высоту → 960×1440.
        # Объявить саму рамку здесь значило бы соврать на 960 пикселей ширины.
        listing.images.first.blob.update!(metadata: { 'width' => 1000, 'height' => 1500 })

        get "/zhk/#{complex.slug}"

        doc = response.parsed_body
        expect(doc.at_css('meta[property="og:image"]')['content'])
          .to include('/rails/active_storage/')
        expect(og(doc, 'width')).to eq('960')
        expect(og(doc, 'height')).to eq('1440')
      end

      # Сегодня основной путь: размеры есть у 414 блобов из 21873, остальные
      # проанализированы без них. Объявляем рамку — приближение (у портрета
      # завышает ширину), но не чужие 1200×630 из дефолта layout. Точным это
      # станет после бэкфилла метаданных, не раньше.
      it 'без размеров в метаданных объявляет рамку варианта, а не дефолт layout' do
        get "/zhk/#{complex.slug}"

        doc = response.parsed_body
        expect(og(doc, 'width')).to eq('1920')
        expect(og(doc, 'height')).to eq('1440')
      end
    end

    # Каталог фото вьюха строит от `Rails.public_path` — его и подменяем.
    # Писать по настоящему пути нельзя: слаг резолвится в реальный ЖК
    # («legenda»), и `rm_rf` снёс бы фотографии, которые редактор туда
    # положит, а прерванный прогон оставил бы 4-байтовую заглушку
    # `og.jpg` — она ломает и соседние примеры, и следующий запуск.
    # Middleware статики захватило свой путь при загрузке приложения,
    # так что подмена задевает только эту вьюху.
    context 'с брендовым og.jpg' do
      # `allow` не переживает `around` — rspec-mocks живёт внутри примера,
      # не снаружи. Потому подмена в before, а уборка в after.
      let(:tmp_public) { Pathname(Dir.mktmpdir) }

      before do
        photo_dir = tmp_public.join("images/zhk/#{complex.slug}")
        photo_dir.mkpath
        photo_dir.join('og.jpg').binwrite("\xFF\xD8\xFF\xD9".b)
        allow(Rails).to receive(:public_path).and_return(tmp_public)
      end

      after { FileUtils.rm_rf(tmp_public) }

      it 'объявляет 1200×630 — размеры самого баннера, не hero-варианта' do
        create(:property, :on_site, residential_complex: complex)

        get "/zhk/#{complex.slug}"

        doc = response.parsed_body
        expect(doc.at_css('meta[property="og:image"]')['content'])
          .to end_with("/images/zhk/#{complex.slug}/og.jpg")
        expect(og(doc, 'width')).to eq('1200')
        expect(og(doc, 'height')).to eq('630')
      end
    end

    context 'без фото и без объектов' do
      it 'оставляет дефолт layout — 1920 не протекает на общую заглушку' do
        get "/zhk/#{complex.slug}"

        doc = response.parsed_body
        expect(og(doc, 'width')).to eq('1200')
        expect(og(doc, 'height')).to eq('630')
      end
    end
  end
end
