# frozen_string_literal: true

# Visibility-decoupling Layer 5 — «Мои объекты» dashboard для client'ов.
#
# Linkage: `Property.owner_user_id` — set'ится через `TopnlabOwnerSyncJob`
# (Owner-sync job, daily 03:00 МСК) OR manually admin via
# /admin/properties → set client_email на consent flow.
#
# Cabinet client видит ВСЕ свои объекты (включая archived/draft) — это
# их собственность, lifecycle visibility делает их хозяевами процесса.
# Группировка by UI-status:
#   - on_site    — 🟢 На сайте (status=:active + published_at)
#   - hidden     — 🚫 Скрыто администратором (force_archive=true)
#   - not_ready  — ⚠ Готовится (нет фото / описания / неправильный deal_state)
#   - sold       — ✓ Продано (deal_state in deal/archive)
#   - archived   — отозвано из CRM (sync long ago, давно не виделся)
#
# Status badge показывает 3-concerns split: site visibility + outbound
# advertising (Avito/Cian — informational, не нужно clientу контролировать)
# + sale lifecycle.
class Cabinet::PropertiesController < ApplicationController
  before_action :require_client_cabinet_user
  before_action :set_own_property, only: %i[hide unhide]

  def index
    @properties = Property.unscoped
                          .where(owner_user_id: @cabinet_user.id)
                          .order(updated_at: :desc)

    @groups = @properties.group_by { |p| ui_status_group(p) }
    @counts = {
      on_site:   @groups[:on_site]&.size.to_i,
      hidden:    @groups[:hidden]&.size.to_i,
      not_ready: @groups[:not_ready]&.size.to_i,
      sold:      @groups[:sold]&.size.to_i,
      archived:  @groups[:archived]&.size.to_i,
      total:     @properties.size
    }

    @stage_pipeline = build_stage_pipeline(@properties)
  end

  # POST /cabinet/properties/:id/hide — client скрывает свой объект с сайта.
  # Optional reason (params[:reason]) → audit-log в Rails.logger.
  def hide
    reason = params[:reason].to_s.strip
    @property.update_columns(force_archive: true, updated_at: Time.current)
    Rails.logger.info(
      "[Cabinet#hide] user=#{@cabinet_user.id} property=#{@property.id} " \
      "reason=#{reason.truncate(80).inspect}"
    )
    redirect_to cabinet_properties_path,
                notice: 'Объект скрыт с сайта. Чтобы вернуть — кнопка «Вернуть на сайт».'
  end

  # POST /cabinet/properties/:id/unhide — обратное действие.
  def unhide
    @property.update_columns(force_archive: false, updated_at: Time.current)
    Rails.logger.info("[Cabinet#unhide] user=#{@cabinet_user.id} property=#{@property.id}")
    redirect_to cabinet_properties_path, notice: 'Объект снова виден на сайте (с учётом готовности).'
  end

  private

  # Только owner может hide/unhide свой объект. unscoped — потому что
  # force_archive properties могут быть в archived статусе и default scope
  # их фильтрует.
  def set_own_property
    @property = Property.unscoped.find_by(id: params[:id], owner_user_id: @cabinet_user.id)
    return if @property

    redirect_to cabinet_properties_path,
                alert: 'Объект не найден среди ваших или не привязан к вашему кабинету.'
  end

  # Priority order matters — каждый предыдущий case стрипает кандидата.
  def ui_status_group(p)
    return :hidden    if p.force_archive
    return :sold      if p.deal_state.to_s.in?(%w[deal archive])
    return :on_site   if p.status_active? && p.published_at.present?
    return :not_ready if p.publication_blockers.any?
    :archived
  end

  # D4 UI — sales pipeline summary для каждого property: сколько buyer-side
  # inquiries в каждой стадии LeadEvent. Возвращает Hash:
  #   { property_id => { 'new' => 3, 'first_contact' => 1, ... } }
  #
  # Two-query plan (avoids N+1):
  #   1. Inquiry.pluck — все inquiries для @properties, мап inquiry_id→property_id
  #   2. LeadEvent.where polymorphic — все LeadEvents для этих inquiries
  # Если нет inquiries (новый объект без интереса) — Hash.new(0) default.
  def build_stage_pipeline(properties)
    return {} if properties.empty?

    property_ids = properties.map(&:id)
    inquiry_to_property = Inquiry.where(property_id: property_ids)
                                 .pluck(:id, :property_id)
                                 .to_h
    return {} if inquiry_to_property.empty?

    pipeline = Hash.new { |h, k| h[k] = Hash.new(0) }
    LeadEvent.where(lead_ref_type: 'Inquiry', lead_ref_id: inquiry_to_property.keys)
             .pluck(:lead_ref_id, :current_stage)
             .each do |inq_id, stage|
      prop_id = inquiry_to_property[inq_id]
      pipeline[prop_id][stage] += 1
    end
    pipeline
  end

  def require_client_cabinet_user
    @cabinet_user = current_cabinet_user
    return if @cabinet_user&.role_client?

    redirect_to cabinet_login_path, alert: 'Доступ только для клиентов в личном кабинете.'
  end
end
