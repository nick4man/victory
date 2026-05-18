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

    # Visibility-decoupling Layer 4 — admin explicit hide (force_archive).
    # Симметричный к force_publish: TRUE → property снимается с сайта
    # независимо от CRM state. Используется для жалоб клиентов / спорных
    # сделок / любого manual reason скрыть от посетителей.
    def toggle_force_archive
      property = Property.unscoped.find(params[:id])
      new_value = !property.force_archive
      property.update_columns(force_archive: new_value, updated_at: Time.current)
      property.publish_if_ready!

      flash[:notice] = if new_value
                         "##{property.id}: СКРЫТ с сайта (force_archive)"
                       else
                         "##{property.id}: показан на сайте"
                       end
      redirect_back fallback_location: admin_properties_path
    end

    # A7 Phase 3 trigger UI: admin requests client signature on agency contract.
    # GET — form view; POST — invoke Cabinet::ConsentRequester + auto-create
    # client User by email if not found.
    def request_consent
      @property = Property.unscoped.find(params[:id])
    end

    def send_consent_request
      @property = Property.unscoped.find(params[:id])
      email = params[:client_email].to_s.strip.downcase
      name = params[:client_name].to_s.strip

      if email.blank? || !email.match?(URI::MailTo::EMAIL_REGEXP)
        flash[:alert] = 'Введите корректный email клиента.'
        redirect_to request_consent_admin_property_path(@property) and return
      end

      if @property.status_pending_consent?
        flash[:alert] = 'Этот объект уже ожидает подписи.'
        redirect_to admin_properties_path and return
      end

      user = find_or_create_client(email, name)
      Cabinet::ConsentRequester.new(@property, user: user).call

      flash[:notice] = "Запрос отправлен на #{email}. Объект ##{@property.id} → ожидает подписи."
      redirect_to admin_properties_path
    rescue Cabinet::ConsentRequester::Error => e
      flash[:alert] = "Не удалось запросить подпись: #{e.message}"
      redirect_to request_consent_admin_property_path(@property)
    rescue ActiveRecord::RecordNotFound
      flash[:alert] = 'Объект не найден.'
      redirect_to admin_properties_path
    end

    private

    def find_or_create_client(email, name)
      user = User.where(active: true, deleted_at: nil)
                 .find_by('LOWER(email) = ?', email)
      return user if user

      # Auto-create — minimum viable client account. Password is random
      # (Devise off — password never used), magic-link auth есть для login.
      first_name, last_name = parse_name(name)
      User.create!(
        email:      email,
        password:   SecureRandom.urlsafe_base64(32),
        first_name: first_name,
        last_name:  last_name,
        role:       'client',
        active:     true,
        crm_status: 'active'
      )
    end

    # «Иван Иванов» → ['Иван', 'Иванов']
    # Если только одно слово или пусто — first_name = слово, last_name = ''.
    def parse_name(full)
      parts = full.to_s.split(/\s+/).reject(&:blank?)
      case parts.size
      when 0 then ['', '']
      when 1 then [parts[0], '']
      else        [parts[0], parts[1..].join(' ')]
      end
    end
  end
end
