# frozen_string_literal: true

module Admin
  # Publication-state dashboard for CRM-synced properties. Surfaces *why*
  # each row isn't on the catalog (deal_state != 'ad', in_ad=false, no
  # images, short content) so the operator can either fix the CRM card
  # or flip the `force_publish` override here.
  #
  # Token-guarded via shared AdminTokenAuth concern.
  class PropertiesController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    def index
      @scope = params[:scope].presence || 'archived'
      base = Property.unscoped.where.not(external_id: nil).order(updated_at: :desc)

      @properties = case @scope
                    when 'published'    then base.where(status: :active).where.not(published_at: nil)
                    when 'archived'     then base.where(status: :archived)
                    when 'force'        then base.where(force_publish: true)
                    else                     base
                    end

      @properties = @properties.page(params[:page]).per(50) if @properties.respond_to?(:page)

      @counts = {
        all:       Property.unscoped.where.not(external_id: nil).count,
        published: Property.unscoped.where(status: :active).where.not(published_at: nil).count,
        archived:  Property.unscoped.where(status: :archived).count,
        force:     Property.unscoped.where(force_publish: true).count
      }
    end

    def toggle_force_publish
      property = Property.unscoped.find(params[:id])
      new_value = !property.force_publish
      property.update_columns(force_publish: new_value, updated_at: Time.current)
      property.publish_if_ready! # apply immediately (publishes if force-on, no-op otherwise)

      flash[:notice] = if new_value
                         "##{property.id}: принудительная публикация ВКЛЮЧЕНА"
                       else
                         "##{property.id}: принудительная публикация выключена"
                       end
      redirect_back fallback_location: admin_properties_path
    end
  end
end
