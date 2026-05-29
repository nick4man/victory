# frozen_string_literal: true

# A7 Phase 3: Digital agency contract signing.
#
# Workflow:
#   1. Admin/agent создаёт Property → status: pending_consent
#   2. ListingConsentMailer.consent_required(property, user) → magic-link email
#   3. Client opens /cabinet/listings/:id/consent → review + sign form
#   4. POST sign → ListingConsent created → Property → status: active
#   5. ListingConsentMailer.signed_confirmation → client gets confirmation
#   6. Agent gets TG notification (via existing Telegram::WorkBot)
#
# Authorization:
#   - require_client_cabinet_user (only role=client in /cabinet session)
#   - Property.pending_consent? — must be в waiting state
#   - User linkage: client связан с Property via existing Inquiry или
#     via explicit owner_user_id (admin-set when создаёт listing)
#
# Audit:
#   - signed_at, IP, UA → ListingConsent record (proof)
#   - consent_text snapshot — full agreement copy на момент signing
#   - content_hash (SHA-256) — tamper detection
class Cabinet::ConsentsController < ApplicationController
  before_action :require_client_cabinet_user
  before_action :set_property, only: %i[show create destroy]

  # GET /cabinet/listings/pending
  # Lists Properties awaiting consent от current user
  def pending
    @pending_properties = pending_for_user.includes(:property_type, images_attachments: :blob)
  end

  # GET /cabinet/listings/:id/consent
  # Review form: property details + full agreement text + sign button
  def show
    return redirect_to_pending if @property.nil?

    @existing_consent = @property.listing_consents.active.where(user: @cabinet_user).first
    @consent_text = build_consent_text(@property)
    @consent_version = ListingConsent::CURRENT_VERSION
  end

  # POST /cabinet/listings/:id/consent
  # Creates ListingConsent + flips Property → active. Idempotent: если
  # уже подписан — возвращает existing record.
  def create
    return redirect_to_pending if @property.nil?

    existing = @property.listing_consents.active.where(user: @cabinet_user).first
    if existing
      redirect_to cabinet_path, notice: 'Согласие уже подписано ранее.' and return
    end

    unless @property.status_pending_consent?
      redirect_to cabinet_path, alert: 'Этот объект не ожидает подписи.' and return
    end

    consent_text = build_consent_text(@property)
    consent = @property.listing_consents.build(
      user:           @cabinet_user,
      signed_at:      Time.current,
      consent_text:   consent_text,
      consent_version: ListingConsent::CURRENT_VERSION,
      ip_address:     request.remote_ip,
      user_agent:     request.user_agent.to_s.first(255)
    )

    ActiveRecord::Base.transaction do
      consent.save!
      # D5 gate: signed_agency_contract_at — required для ready_for_site?
      # Set вместе с status:active чтобы publish_if_ready? проходил.
      @property.update!(
        status: :active,
        published_at: Time.current,
        signed_agency_contract_at: consent.signed_at
      )
    end

    # Side-effects (after-commit to ensure they fire even if email/TG fails)
    deliver_signed_confirmation(consent)
    notify_agent_via_telegram(consent)

    redirect_to cabinet_path,
                notice: "Согласие подписано. Объект опубликован. Договор сохранён под номером ##{consent.id}."
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[Cabinet::ConsentsController] sign failed: #{e.message}")
    redirect_to cabinet_listing_consent_path(@property),
                alert: "Не удалось подписать: #{e.message}"
  end

  # GET /cabinet/listings/:id/consent.pdf
  # Download PDF version of signed agency contract. Generates через
  # AgencyContractPdfService — gold-accent layout с QR-кодом верификации.
  # Owner-only: @cabinet_user должен быть signer.
  def pdf
    return redirect_to_pending if @property.nil?

    consent = @property.listing_consents.where(user: @cabinet_user).order(signed_at: :desc).first
    if consent.nil?
      redirect_to cabinet_listing_consent_path(@property),
                  alert: 'Подписанный договор не найден. Сначала подпишите.' and return
    end

    pdf_bytes = AgencyContractPdfService.new(consent).call
    filename = "agency-contract-#{@property.id}-#{consent.signed_at.strftime('%Y%m%d')}.pdf"
    send_data pdf_bytes,
              filename:    filename,
              type:        'application/pdf',
              disposition: 'inline'
  rescue StandardError => e
    Rails.logger.error("[Cabinet::ConsentsController#pdf] failed: #{e.class}: #{e.message}")
    redirect_to cabinet_listing_consent_path(@property), alert: 'Не удалось сгенерировать PDF.'
  end

  # DELETE /cabinet/listings/:id/consent
  # Revoke (только до публикации = до того, как объект увидел трафик).
  # Soft via revoked_at + Property → pending_consent.
  def destroy
    return redirect_to_pending if @property.nil?

    consent = @property.listing_consents.active.where(user: @cabinet_user).first
    return redirect_to(cabinet_path, alert: 'Активное согласие не найдено.') unless consent

    ActiveRecord::Base.transaction do
      consent.update!(revoked_at: Time.current, revocation_reason: params[:reason].to_s.first(500))
      @property.update!(status: :pending_consent)
    end

    redirect_to cabinet_path, notice: 'Согласие отозвано. Объект снят с публикации.'
  end

  private

  def require_client_cabinet_user
    @cabinet_user = current_cabinet_user
    return if @cabinet_user&.role_client?

    redirect_to cabinet_login_path, alert: 'Доступ только для клиентов в личном кабинете.'
  end

  def set_property
    @property = pending_for_user.find_by(id: params[:id])
  end

  def redirect_to_pending
    redirect_to cabinet_pending_consents_path,
                alert: 'Объект не найден или не ожидает вашей подписи.'
  end

  # Linkage logic: client может подписать только те Properties, где:
  #   1. Property.owner_user_id == cabinet_user.id (admin явно привязал)
  #   2. OR Inquiry.where(property_id: P, ...email matches...).exists?
  #      (client уже обратился по этому объекту в качестве seller'а)
  def pending_for_user
    scope = Property.unscoped.where(status: Property.statuses[:pending_consent])

    user_id = @cabinet_user.id
    email = @cabinet_user.email.to_s.downcase

    # Owner_user_id linkage (explicit admin assignment)
    owner_property_ids = scope.where(owner_user_id: user_id).pluck(:id)

    # Inquiry-based linkage (email match)
    inquiry_property_ids = Inquiry.where('LOWER(email) = ?', email)
                                  .where.not(property_id: nil)
                                  .pluck(:property_id)
                                  .uniq

    linked_ids = (owner_property_ids + inquiry_property_ids).uniq
    scope.where(id: linked_ids)
  end

  # Builds the agreement text snapshot за momentum signing.
  # Real text source — `app/views/cabinet/consents/_agreement_template.html.erb`
  # rendered с current Property substitutions. Stored как text (not HTML)
  # для legal clarity.
  def build_consent_text(property)
    # Pass property + cabinet_user + agency info as locals
    render_to_string(
      partial: 'cabinet/consents/agreement_template',
      locals: { property: property, user: @cabinet_user },
      formats: [:text]
    ).to_s.strip
  end

  def deliver_signed_confirmation(consent)
    ListingConsentMailer.signed_confirmation(consent).deliver_later
  rescue StandardError => e
    Rails.logger.warn("[Cabinet::ConsentsController] mailer failed: #{e.message}")
  end

  # Notification агенту в TG: подписано, объект опубликован.
  # Mirror existing LeadAnnouncer pattern through TopicRegistry.
  def notify_agent_via_telegram(consent)
    text = "✅ <b>Согласие подписано</b>\n\n" \
           "Объект: #{consent.property.title}\n" \
           "Адрес: #{consent.property.address}\n" \
           "Клиент: #{[@cabinet_user.first_name, @cabinet_user.last_name].compact_blank.join(' ').presence || @cabinet_user.email}\n" \
           "Договор ##{consent.id} · #{consent.signed_at.strftime('%d.%m.%y %H:%M')}\n" \
           "Объект автоматически опубликован."

    Telegram::Client.new.send_message(
      text,
      chat_id: Telegram::TopicRegistry.chat_id,
      message_thread_id: Telegram::TopicRegistry.thread_id('dispatcher'),
      parse_mode: 'HTML'
    )
  rescue StandardError => e
    Rails.logger.warn("[Cabinet::ConsentsController] TG notify failed: #{e.message}")
  end
end
