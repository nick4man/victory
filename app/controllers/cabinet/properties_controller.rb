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
  end

  private

  # Priority order matters — каждый предыдущий case стрипает кандидата.
  def ui_status_group(p)
    return :hidden    if p.force_archive
    return :sold      if p.deal_state.to_s.in?(%w[deal archive])
    return :on_site   if p.status_active? && p.published_at.present?
    return :not_ready if p.publication_blockers.any?
    :archived
  end

  def require_client_cabinet_user
    @cabinet_user = current_cabinet_user
    return if @cabinet_user&.role_client?

    redirect_to cabinet_login_path, alert: 'Доступ только для клиентов в личном кабинете.'
  end
end
