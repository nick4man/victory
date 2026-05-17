# frozen_string_literal: true

# A7 Phase 3: trigger consent flow для конкретной Property.
#
# Admin/agent вызывает этот сервис когда хочет request signature от клиента:
#   Cabinet::ConsentRequester.new(property, user: client_user).call
#
# Side effects:
#   1. Property.status = pending_consent (если был draft / pending / archived)
#   2. ListingConsentMailer.consent_required → email клиенту с magic-link
#
# Linkage:
#   - user — either explicit (admin-known client) OR auto-derived из
#     Inquiry.where(property_id: property.id).first&.user
#   - если user не найден — raise ArgumentError (admin должен явно указать)
#
# Не trigger'ится автоматически на Property after_create — чтобы legacy
# imports и admin testing не ломались.
class Cabinet::ConsentRequester
  class Error < StandardError; end

  def initialize(property, user: nil)
    @property = property
    @user = user || infer_user
  end

  def call
    raise Error, 'Property не передан' if @property.nil?
    raise Error, 'User не найден — укажите client_user_id вручную' if @user.nil?
    raise Error, 'User должен иметь role=client' unless @user.role_client?

    flip_to_pending_consent!
    send_email!

    Rails.logger.info(
      "[Cabinet::ConsentRequester] property=#{@property.id} user=#{@user.id} " \
      "status_flipped=#{@property.status_pending_consent?}"
    )

    { property: @property, user: @user, status: @property.status }
  end

  private

  # Linkage rule: ищем Inquiry с этим property_id, берём User через email match.
  def infer_user
    return nil if @property.nil?

    Inquiry.where(property_id: @property.id).where.not(email: nil).find_each do |i|
      candidate = User.where(active: true, deleted_at: nil)
                      .find_by('LOWER(email) = ?', i.email.to_s.downcase)
      return candidate if candidate
    end
    nil
  end

  def flip_to_pending_consent!
    return if @property.status_pending_consent?

    @property.update!(status: :pending_consent)
  end

  def send_email!
    ListingConsentMailer.consent_required(@property, @user).deliver_later
  rescue StandardError => e
    Rails.logger.warn("[Cabinet::ConsentRequester] mailer failed: #{e.class}: #{e.message}")
    # Не raise — email отправка не должна откатывать status flip
  end
end
