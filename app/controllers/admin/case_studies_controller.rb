# frozen_string_literal: true

module Admin
  # Token-guarded CaseStudy admin. Mirrors Admin::ArticlesController
  # auth pattern (AdminTokenAuth — ?token=ADMIN_TOKEN или session cookie).
  #
  # Workflow:
  #   1. Admin создаёт draft (new → create) или вызывает case-study-writer
  #      agent для генерации body markdown.
  #   2. Редактирует body + metadata в /admin/case_studies/:id/edit.
  #   3. Жмёт «Опубликовать» (member action publish) — status →
  #      published, published_at = now.
  #   4. Если кейс устарел — member action archive (status → archived).
  #   5. soft_delete полностью скрывает кейс из выдачи (deleted_at set).
  class CaseStudiesController < ApplicationController
    include AdminTokenAuth
    layout 'application'
    before_action :set_case_study, only: %i[edit update destroy publish archive soft_delete]

    def index
      @scope = params[:scope].presence || 'visible'
      base = CaseStudy.unscoped.order(created_at: :desc)
      @case_studies = case @scope
                      when 'draft'    then base.where(status: CaseStudy.statuses[:draft], deleted_at: nil)
                      when 'archived' then base.where(status: CaseStudy.statuses[:archived], deleted_at: nil)
                      when 'deleted'  then base.where.not(deleted_at: nil)
                      else                  base.where(status: CaseStudy.statuses[:published], deleted_at: nil)
                      end
      @counts = {
        visible:  CaseStudy.unscoped.where(status: CaseStudy.statuses[:published], deleted_at: nil).count,
        draft:    CaseStudy.unscoped.where(status: CaseStudy.statuses[:draft], deleted_at: nil).count,
        archived: CaseStudy.unscoped.where(status: CaseStudy.statuses[:archived], deleted_at: nil).count,
        deleted:  CaseStudy.unscoped.where.not(deleted_at: nil).count
      }
    end

    def new
      @case_study = CaseStudy.new(status: :draft, property_type: :flat)
    end

    def create
      @case_study = CaseStudy.new(case_study_params)
      @case_study.published_at ||= Time.current if @case_study.status_published?
      if @case_study.save
        redirect_to admin_case_studies_path(token: params[:token]), notice: 'Кейс создан.'
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @case_study.update(case_study_params)
        redirect_to admin_case_studies_path(token: params[:token]), notice: 'Сохранено.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def publish
      @case_study.update!(status: :published, published_at: @case_study.published_at || Time.current)
      redirect_back fallback_location: admin_case_studies_path, notice: 'Кейс опубликован.'
    end

    def archive
      @case_study.update!(status: :archived)
      redirect_back fallback_location: admin_case_studies_path, notice: 'Кейс архивирован.'
    end

    def soft_delete
      @case_study.soft_delete!
      redirect_back fallback_location: admin_case_studies_path, notice: 'Кейс удалён (soft-delete).'
    end

    def destroy
      # Hard delete только для черновиков без relation'ов.
      @case_study.destroy!
      redirect_to admin_case_studies_path(token: params[:token]), notice: 'Кейс удалён без возможности восстановления.'
    end

    private

    def set_case_study
      @case_study = CaseStudy.unscoped.friendly.find(params[:id])
    end

    def case_study_params
      params.require(:case_study).permit(
        :title, :slug, :excerpt, :body,
        :client_alias, :client_origin, :client_profession,
        :district, :property_type, :area, :deal_amount, :deal_duration_days,
        :bank, :mortgage_program,
        :author_id, :inquiry_id, :property_id,
        :meta_title, :meta_description, :og_image_url,
        :status, :published_at
      )
    end
  end
end
