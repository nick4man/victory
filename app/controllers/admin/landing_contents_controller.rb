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

    # Receives a single file via the form's drag-and-drop block editor.
    # Returns the ActiveStorage signed_id so the JS can embed it into
    # the in-progress block. The image is attached to a "scratch" LandingContent
    # if its id is sent; otherwise it's a free-floating blob that the
    # LandingContent picks up when the parent form is submitted.
    def upload_image
      blob = ActiveStorage::Blob.create_and_upload!(
        io: params.require(:file),
        filename: params[:file].original_filename,
        content_type: params[:file].content_type
      )
      render json: {
        signed_id: blob.signed_id,
        filename:  blob.filename.to_s,
        url:       url_for(blob)
      }
    rescue StandardError => e
      Rails.logger.warn("[Admin::LandingContents#upload_image] #{e.class}: #{e.message}")
      render json: { error: e.message }, status: :unprocessable_entity
    end

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
      @landing_content.body_blocks = parsed if parsed.is_a?(Array)
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
