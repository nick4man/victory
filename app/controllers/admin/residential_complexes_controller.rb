# frozen_string_literal: true

module Admin
  # Справочник ЖК: карточки, редакционный текст, привязка объектов каталога.
  # A2 Фаза 2 (09.08.26). Публичные страницы /zhk/:slug — Фаза 3.
  #
  # Наполняется только руками: Topnlab название ЖК не отдаёт вовсе, поэтому
  # этот экран — единственный источник данных для будущего SEO-слоя.
  class ResidentialComplexesController < ApplicationController
    include AdminTokenAuth
    include Admin::UploadsBlockImages
    layout 'application'

    before_action :set_complex,
                  only: %i[edit update publish unpublish soft_delete restore
                           listings attach_properties detach_property]

    # Вьюха экрана привязки прокидывает те же фильтры в form action, чтобы
    # после сабмита оператор вернулся к своей выборке, а не к «авто».
    helper_method :listings_filters

    def index
      @scope = params[:scope].presence || 'all'
      @complexes = scoped_complexes.page(params[:page]).per(50)
      @counts = counts_by_scope

      # Один grouped-count на всю страницу. ResidentialComplex#on_site_listings_count
      # мемоизирован per-instance, поэтому в цикле по 50 строкам он дал бы
      # 50 запросов — не «упрощать» обратно.
      @listing_counts = Property.on_site
                                .where(residential_complex_id: @complexes.map(&:id))
                                .group(:residential_complex_id).count
      @photo_counts = Zhk::Coverage.photo_counts_by_slug
      @duplicate_leads = Zhk::Coverage.duplicate_first_paragraphs
    end

    def new
      @complex = ResidentialComplex.new(city: 'Рязань', body_blocks: [])
    end

    def create
      @complex = ResidentialComplex.new(normalized_params)
      assign_body_blocks_from_form
      if @complex.save
        redirect_to edit_admin_residential_complex_path(@complex), notice: 'ЖК создан.'
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      assign_body_blocks_from_form
      if @complex.update(normalized_params)
        redirect_to edit_admin_residential_complex_path(@complex), notice: 'Сохранено.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def publish
      @complex.update!(published: true)
      redirect_back fallback_location: admin_residential_complexes_path, notice: 'Опубликован.'
    end

    def unpublish
      @complex.update!(published: false)
      redirect_back fallback_location: admin_residential_complexes_path, notice: 'Снят с публикации.'
    end

    def soft_delete
      @complex.soft_delete!
      redirect_to admin_residential_complexes_path,
                  notice: 'ЖК удалён. Привязки объектов сохранены и вернутся вместе с ним.'
    end

    # Возвращаем черновиком намеренно: иначе удалённый-и-восстановленный ЖК
    # мгновенно снова в проде, минуя ревизию текста.
    def restore
      @complex.update!(deleted_at: nil, published: false)
      redirect_back fallback_location: admin_residential_complexes_path,
                    notice: 'ЖК восстановлен как черновик.'
    end

    # Экран привязки — отдельный от формы: тут пагинация и переключение
    # стратегий, а `?page=` на форме терял бы несохранённые правки.
    def listings
      @attached = @complex.properties.order(updated_at: :desc)
      @suggestion = Zhk::AttachmentSuggester.call(
        @complex,
        strategy: params[:strategy],
        radius_km: params[:radius].presence&.to_f,
        query: params[:q]
      )
      @candidates = @suggestion.candidates.page(params[:page]).per(30)
    end

    def attach_properties
      ids = Array(params[:property_ids]).map(&:to_i).reject(&:zero?)

      # Скоуп тот же, что у пула подсказчика. Без него устаревшая форма или
      # ручной запрос молча перетащили бы объект у другого ЖК (прежний
      # потерял бы его без следа) либо привязали архивный/чужого города —
      # тот, который подсказчик никогда не показывал бы.
      attached = Property.on_site.where(id: ids, residential_complex_id: nil)
                         .in_city(@complex.city)
                         .update_all(residential_complex_id: @complex.id, updated_at: Time.current)

      skipped = ids.size - attached
      notice = "Привязано объектов: #{attached}."
      notice += " Пропущено: #{skipped} — уже привязаны к другому ЖК, не на сайте или из другого города." if skipped.positive?

      redirect_to listings_admin_residential_complex_path(@complex, listings_filters), notice: notice
    end

    def detach_property
      # Скоуп по complex_id: устаревшая форма не отвяжет чужой объект.
      Property.where(id: params[:property_id], residential_complex_id: @complex.id)
              .update_all(residential_complex_id: nil, updated_at: Time.current)
      redirect_back fallback_location: listings_admin_residential_complex_path(@complex),
                    notice: 'Объект отвязан.'
    end

    private

    # unscoped снимает default_scope { not_deleted } — таб «удалённые» иначе
    # был бы пуст, а soft-delete необратим без консоли.
    def set_complex
      @complex = ResidentialComplex.unscoped.friendly.find(params[:id])
    end

    def scoped_complexes
      base = ResidentialComplex.unscoped.order(:name)
      case @scope
      when 'published' then base.where(published: true, deleted_at: nil)
      when 'drafts'    then base.where(published: false, deleted_at: nil)
      when 'deleted'   then base.where.not(deleted_at: nil)
      else                  base.where(deleted_at: nil)
      end
    end

    def counts_by_scope
      base = ResidentialComplex.unscoped
      {
        all:       base.where(deleted_at: nil).count,
        published: base.where(published: true, deleted_at: nil).count,
        drafts:    base.where(published: false, deleted_at: nil).count,
        deleted:   base.where.not(deleted_at: nil).count
      }
    end

    def listings_filters
      params.permit(:strategy, :radius, :q).to_h.compact_blank
    end

    def complex_params
      params.require(:residential_complex).permit(
        :name, :slug, :city, :district_slug, :developer, :address,
        :latitude, :longitude,
        :built_from, :built_to, :buildings_count, :floors_min, :floors_max,
        :wall_material, :housing_class, :build_status,
        :has_parking, :has_closed_yard, :has_playground, :has_kindergarten, :has_school,
        :title, :meta_description, :published
      )
    end

    # address_patterns редактируется textarea (паттерн в строке), а не
    # массивным полем: массив в HTML-форме требует JS для добавления строк,
    # а полностью очистить его без hidden-заглушки нельзя — с заглушкой же
    # приходит [""]. Проверка на nil, а не blank?, именно чтобы пустая
    # textarea очищала массив.
    def normalized_params
      attrs = complex_params
      raw = params.dig(:residential_complex, :address_patterns_text)
      return attrs if raw.nil?

      attrs.merge(address_patterns: raw.to_s.split("\n").map(&:strip).compact_blank.uniq)
    end

    # Тот же контракт, что у лендингов: форма отдаёт плоский JSON, маркер
    # отличает живой редактор от не поднявшегося (иначе пустой массив стёр
    # бы текст — см. PR #15).
    def assign_body_blocks_from_form
      raw = params.dig(:residential_complex, :body_blocks_json)
      return if raw.blank?

      parsed = JSON.parse(raw)
      return unless parsed.is_a?(Array)

      editor_alive = params.dig(:residential_complex, :body_blocks_editor) == '1'
      return if parsed.empty? && !editor_alive && @complex.body_blocks.present?

      @complex.body_blocks = parsed
    rescue JSON::ParserError => e
      Rails.logger.warn("[Admin::ResidentialComplexes] bad body_blocks_json: #{e.message}")
    end
  end
end
