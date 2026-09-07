# frozen_string_literal: true

# Публичные страницы жилых комплексов (A2 Фаза 3) — entity-layer под
# бренд-запросы («ЖК Легенда Рязань», «Скобелев купить квартиру»),
# перпендикулярный intent×type пирамиде `LandingsController`.
# См. .claude/plans/seo/a2-zhk-landings.md, секция «Фаза 3».
#
# Индексация подчиняется `ResidentialComplex#indexable?` (текст ЛИБО живые
# объекты) — условие сознательно инкапсулировано в модели, здесь не
# дублируется (см. комментарий класса модели: расхождение sitemap/robots
# Яндекс демотирует).
class ResidentialComplexesController < ApplicationController
  include RendersNotFound

  # Ниже этого порога `/zhk` остаётся 200, но с noindex,follow — страница
  # существует и полезна редким прямым заходам, но как отдельная точка
  # входа в выдачу ещё не готова. Тот же порог — гейт мержа PR (см. план).
  HUB_MIN_COMPLEXES = 3

  # Хаб пока рязанский: заголовок, description и H1 говорят «Рязани», и
  # выборка обязана этому соответствовать. Модель валидирует город против
  # Cities::REGISTRY, то есть московский или питерский ЖК завести можно —
  # без этого фильтра первый же такой попал бы в список под рязанским H1.
  # Мультигородский хаб — отдельная работа (свой роут, свой title).
  HUB_CITY = 'Рязань'

  # 48 карточек на страницу — и столько же обещает ItemList в разметке.
  LISTINGS_LIMIT = 48

  def index
    @complexes      = ResidentialComplex.visible.sitemap_ready.in_city(HUB_CITY).order(:name).to_a
    @listing_counts = on_site_counts_for(@complexes)
    @hub_ready      = @complexes.size >= HUB_MIN_COMPLEXES

    expires_in 15.minutes

    @meta_title       = 'Жилые комплексы Рязани — новостройки от АН «Виктори»'
    @meta_description = hub_meta_description

    add_breadcrumb 'Каталог', properties_path
    add_breadcrumb 'Жилые комплексы'
  end

  def show
    @complex = ResidentialComplex.visible.friendly.find(params[:id])
    # 301 и 404 кэшировать нельзя: редактор публикует ЖК и ещё четверть
    # часа видел бы по своей же ссылке «страница не найдена». Поэтому
    # expires_in стоит ПОСЛЕ разрешения записи и редиректа, а не первой
    # строкой, как в LandingsController.
    return redirect_to zhk_path(@complex), status: :moved_permanently if params[:id] != @complex.slug

    expires_in 15.minutes

    @stats    = ListingStats.for(listings_scope)
    # Тот же COUNT уже посчитан в агрегатах — отдаём его модели, чтобы
    # `indexable?` во вьюхе не ходил в базу второй раз за тем же числом.
    @complex.on_site_listings_count = @stats.count
    # with_attached_images — иначе карточка объекта дёргает ActiveStorage
    # на каждый объект: замер на 5 объектах давал 18 запросов к
    # active_storage_*, а на полной странице их было бы под сотню. Эта
    # страница живёт ради crawl-квоты, TTFB тут не роскошь.
    @listings = listings_scope.with_attached_images.limit(LISTINGS_LIMIT).to_a

    @meta_title       = @complex.title.presence || default_title
    @meta_description = @complex.meta_description.presence || build_meta_description

    add_breadcrumb 'Каталог', properties_path
    add_breadcrumb 'Жилые комплексы', zhk_index_path
    add_breadcrumb @complex.name
  rescue ActiveRecord::RecordNotFound
    render_not_found("Unknown ЖК slug: #{params[:id]}")
  end

  private

  # Один групповой запрос вместо COUNT(*) на каждую карточку хаба: на
  # восьми ЖК было девять обращений к properties, стало одно.
  def on_site_counts_for(complexes)
    return {} if complexes.empty?

    Property.on_site.where(residential_complex_id: complexes.map(&:id))
            .group(:residential_complex_id).count
  end

  # На пустом справочнике фраза «0 объектов с описанием» звучала бы как
  # неисправность — на этот случай description без счётчика.
  def hub_meta_description
    if @complexes.empty?
      'Каталог жилых комплексов Рязани: описания, фактура и актуальные предложения ' \
        "от АН «Виктори». Звоните: #{AgencyInfo::PHONE_PRIMARY}"
    else
      "Каталог жилых комплексов Рязани: #{@complexes.size} объектов с описанием, " \
        "фактурой и актуальными предложениями от АН «Виктори». Звоните: #{AgencyInfo::PHONE_PRIMARY}"
    end
  end

  # Мемоизирован — единственная точка сборки scope для этого запроса,
  # используется и агрегатами (ListingStats), и списком карточек. Эталон
  # (`LandingsController#build_scope`) пересобирает scope до 4× за запрос —
  # здесь так делать не нужно, ЖК не фасетируется по intent/type/rooms.
  def listings_scope
    @listings_scope ||= @complex.on_site_listings.order(created_at: :desc)
  end

  # Короткий шаблон намеренно: бренд-название ЖК уже несёт основной вес
  # запроса («ЖК Легенда»), обвязка — только район и площадка. У ЖК с
  # длинным составным названием (тип «Дашково-Песочня, Старое Село 2»)
  # заголовок всё равно превысит 60 символов — для таких редактор
  # переопределяет через поле `title` в админке (для этого оно и есть).
  def default_title
    "ЖК «#{@complex.name}», #{location_label} — квартиры | АН «Виктори»"
  end

  def location_label
    @complex.district_name.presence || @complex.city
  end

  # ≤160 символов — сознательно короче LandingsController#build_meta_description
  # (тот давно перевалил за лимит): у ЖК название само по себе съедает
  # значимую часть бюджета, застройщика/фактуру в description не дублируем —
  # они уже в JSON-LD additionalProperty и на самой странице.
  def build_meta_description
    price_from = (formatted = helpers.zhk_format_min_price(@stats.min_price)) ? " от #{formatted} ₽" : ''

    if @stats.count.positive?
      "ЖК «#{@complex.name}», #{location_label}: #{@stats.count} предложений#{price_from}. " \
        'Планировки, цены, консультация. Звоните: ' + AgencyInfo::PHONE_PRIMARY
    else
      "ЖК «#{@complex.name}», #{location_label}. Планировки, инфраструктура, цены — " \
        'консультация АН «Виктори». Звоните: ' + AgencyInfo::PHONE_PRIMARY
    end
  end
end
