# frozen_string_literal: true

module Admin
  # Admin CRUD for the editable SEO landing content. Token-guarded via the
  # shared AdminTokenAuth concern (no Devise, ?token= or session cookie
  # from /admin/login).
  #
  # Index doubles as a coverage map: it lists existing rows AND highlights
  # the (intent, type, district) slots that don't have a row yet so the
  # team knows what still needs editorial copy.
  class LandingContentsController < ApplicationController
    include AdminTokenAuth
    include Admin::UploadsBlockImages
    layout 'application'

    before_action :set_landing_content, only: %i[show edit update destroy publish unpublish]

    def index
      @scope = params[:scope].presence || 'all'
      base = LandingContent.order(intent: :asc, type: :asc, district_slug: :asc)
      @landing_contents = case @scope
                          when 'published' then base.where(published: true)
                          when 'drafts'    then base.where(published: false)
                          else                  base
                          end
      @counts = {
        all:       LandingContent.count,
        published: LandingContent.where(published: true).count,
        drafts:    LandingContent.where(published: false).count
      }
      # Coverage map — which district slugs don't have a kvartira-sale row yet?
      existing_kvartira_slugs = LandingContent.where(intent: 'sale', type: 'kvartira', rooms: nil)
                                              .where.not(district_slug: nil).pluck(:district_slug).to_set
      @missing_district_slugs = RyazanDistricts.all_micro_slugs - existing_kvartira_slugs.to_a
    end

    def show; end

    def new
      @landing_content = LandingContent.new(intent: 'sale', type: 'kvartira', body_blocks: [])
    end

    def create
      @landing_content = LandingContent.new(landing_content_params)
      assign_body_blocks_from_form
      if @landing_content.save
        attach_images_if_any
        redirect_to edit_admin_landing_content_path(@landing_content), notice: 'SEO-страница создана.'
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      assign_body_blocks_from_form
      if @landing_content.update(landing_content_params)
        attach_images_if_any
        redirect_to edit_admin_landing_content_path(@landing_content), notice: 'Сохранено.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @landing_content.destroy!
      redirect_to admin_landing_contents_path, notice: 'Удалено.'
    end

    def publish
      @landing_content.update!(published: true)
      redirect_back fallback_location: admin_landing_contents_path, notice: 'Опубликовано.'
    end

    def unpublish
      @landing_content.update!(published: false)
      redirect_back fallback_location: admin_landing_contents_path, notice: 'Снято с публикации.'
    end

    # upload_image — в concern Admin::UploadsBlockImages (общий с ЖК).

    private

    def set_landing_content
      @landing_content = LandingContent.find(params[:id])
    end

    def landing_content_params
      params.require(:landing_content).permit(
        :intent, :type, :district_slug, :rooms,
        :title, :meta_description, :published
      )
    end

    # The form submits a flat JSON blob in `landing_content[body_blocks_json]`
    # (built by the JS block editor). Parse it out of band so the JSON shape
    # doesn't have to be reflected in strong-params nesting.
    def assign_body_blocks_from_form
      raw = params.dig(:landing_content, :body_blocks_json)
      return if raw.blank?

      parsed = JSON.parse(raw)
      return unless parsed.is_a?(Array)

      # Пустой массив принимаем только от живого редактора (маркер ставит JS
      # после успешной загрузки блоков). «Удалить все блоки» — легитимный
      # сценарий, а вот POST из редактора, который не поднялся, не должен
      # стирать текст: именно так 09.08.26 обнаружилась потеря контента.
      editor_alive = params.dig(:landing_content, :body_blocks_editor) == '1'
      return if parsed.empty? && !editor_alive && @landing_content.body_blocks.present?

      @landing_content.body_blocks = parsed
    rescue JSON::ParserError => e
      Rails.logger.warn("[Admin::LandingContents] bad body_blocks_json: #{e.message}")
    end

    # Any uploaded photos attached directly (multipart in the form) — we
    # still attach them to LandingContent#images so AS retains them. The
    # block payload references images by signed_id regardless.
    def attach_images_if_any
      files = Array(params.dig(:landing_content, :images))
      files.each { |f| @landing_content.images.attach(f) if f.respond_to?(:original_filename) }
    end
  end
end
