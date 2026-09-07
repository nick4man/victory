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

  def index
    expires_in 15.minutes, public: true

    @complexes = ResidentialComplex.visible.sitemap_ready.order(:name).to_a
    @hub_ready = @complexes.size >= HUB_MIN_COMPLEXES

    @meta_title       = 'Жилые комплексы Рязани — новостройки от АН «Виктори»'
    @meta_description = "Каталог жилых комплексов Рязани: #{@complexes.size} объектов с описанием, " \
                         'фактурой и актуальными предложениями от АН «Виктори». Звоните: ' +
                         AgencyInfo::PHONE_PRIMARY

    add_breadcrumb 'Каталог', properties_path
    add_breadcrumb 'Жилые комплексы'
  end

  def show
    expires_in 15.minutes, public: true

    @complex = ResidentialComplex.visible.friendly.find(params[:id])
    return redirect_to zhk_path(@complex), status: :moved_permanently if params[:id] != @complex.slug

    @stats    = ListingStats.for(listings_scope)
    @listings = listings_scope.limit(48).to_a

    @meta_title       = @complex.title.presence || default_title
    @meta_description = @complex.meta_description.presence || build_meta_description

    add_breadcrumb 'Каталог', properties_path
    add_breadcrumb 'Жилые комплексы', zhk_index_path
    add_breadcrumb @complex.name
  rescue ActiveRecord::RecordNotFound
    render_not_found("Unknown ЖК slug: #{params[:id]}")
  end

  private

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
