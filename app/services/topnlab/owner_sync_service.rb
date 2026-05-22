# frozen_string_literal: true

# Pulls seller-client linkage from Topnlab into Property#owner_user_id.
#
# Background: Topnlab stores the property OWNER (seller/landlord — физлицо) as
# a separate client entity attached to the realty card. The main
# `get-entities` response only has the *agent* (`user.email`). To get the
# seller we must call `/clients/get-by-entity` (entity_type=2) per card.
#
# Strategy (idempotent, additive):
#   1. Fetch properties that are synced from Topnlab and have owner_user_id = nil.
#   2. For each property, call get_clients_by_entity.
#   3. For each returned client, find-or-create a User row (role=:client).
#      Match by email first; fall back to phone; create only if at least
#      one of email/phone is present.
#   4. Set property.owner_user_id = user.id (first client wins if multiple).
#
# SAFETY:
#   - Never overwrites an existing owner_user_id (additive only).
#   - Never deletes User rows.
#   - Rate: 1 API call per property at 1 req/s (FAST_DELAY). For 73 active
#     properties this takes ~75 seconds — run as a background job, not inline.
#
# CABINET IMPACT:
#   After owner_user_id is set, `/cabinet` dashboard can show:
#     Property.where(owner_user_id: cabinet_user.id) → "мои объекты"
#   This is already wired in `cabinet/consents_controller.rb` (line 131).
#
# P2 TODO: call this on webhook `type=realty` events too (after property import).
module Topnlab
  class OwnerSyncService
    # Limit per run to avoid >10-min job runtime on very large catalogs.
    BATCH_LIMIT = 200

    def initialize(client: Topnlab::Client.new)
      @client = client
    end

    # @param limit [Integer] max properties to process per run (default BATCH_LIMIT)
    # @return [Hash] { processed:, linked:, created_users:, skipped:, errors: [] }
    def call(limit: BATCH_LIMIT)
      properties = Property.unscoped
                           .where(external_source: 'topnlab', owner_user_id: nil)
                           .where.not(external_id: nil)
                           .limit(limit)
                           .order(:id)

      processed     = 0
      linked        = 0
      created_users = 0
      skipped       = 0
      errors        = []

      properties.each do |property|
        topnlab_id = property.external_id.to_i
        next if topnlab_id.zero?

        clients_payload = @client.get_clients_by_entity(entity_id: topnlab_id, entity_type: 2)
        processed += 1

        if clients_payload.empty?
          skipped += 1
          next
        end

        # Use only the first client record (primary seller). Multiple clients
        # per object (e.g. co-owners) are rare and unsupported in cabinet v1.
        client_data = clients_payload.first
        user, was_created = find_or_create_user_from_client(client_data)

        if user
          property.update_columns(owner_user_id: user.id)
          linked        += 1
          created_users += 1 if was_created
          send_cabinet_invitation(user, property)
        else
          skipped += 1
          Rails.logger.info(
            "[OwnerSync] property #{property.id} (topnlab=#{topnlab_id}): " \
            'client has no email/phone — skipped'
          )
        end
      rescue StandardError => e
        errors << "property #{property.id}: #{e.class}: #{e.message.truncate(200)}"
        Rails.logger.error("[OwnerSync] #{errors.last}")
        Sentry.capture_exception(e, extra: { property_id: property.id, topnlab_id: topnlab_id }) if defined?(Sentry)
      end

      summary = { processed: processed, linked: linked, created_users: created_users,
                  skipped: skipped, errors: errors }
      Rails.logger.info("[OwnerSync] #{summary}")
      summary
    end

    private

    # Returns [User, created_boolean] or [nil, false].
    # Match priority: email → phone → none (skip).
    # Creates with role=:client, active=true.  Never overwrites existing user's role.
    def find_or_create_user_from_client(data)
      email = extract_email(data)
      phone = extract_phone(data)

      # Try to find existing user
      user = find_existing_user(email, phone)
      return [user, false] if user

      # Need at least email or phone to create a usable account
      return [nil, false] if email.blank? && phone.blank?

      # Email-only creation (magic-link login requires email). If we only have
      # phone, we create the User but they can't login via magic-link until
      # we collect their email (e.g. consent form, agent update).
      attrs = build_user_attrs(data, email, phone)
      user = User.new(attrs)
      if user.save(validate: false)
        [user, true]
      else
        Rails.logger.warn("[OwnerSync] User create failed: #{user.errors.full_messages.inspect}")
        [nil, false]
      end
    rescue ActiveRecord::RecordNotUnique
      # Race condition — another process created the same user between find and create.
      user = find_existing_user(email, phone)
      [user, false]
    end

    # D3 — Send «вам привязан объект» invitation через channel-priority chain.
    # Логика делегирована CabinetInvitationDispatcher: email → TG → SMS
    # (cheapest reliable channel first).
    #
    # См. `app/services/cabinet_invitation_dispatcher.rb` для деталей про
    # idempotency, failure-isolation, и mask_email.
    def send_cabinet_invitation(user, property)
      return unless user.respond_to?(:invited_at)

      CabinetInvitationDispatcher.call(user, property)
    rescue StandardError => e
      Rails.logger.warn("[OwnerSync] invitation failed user=#{user.id}: #{e.class}: #{e.message}")
      Sentry.capture_exception(e, extra: { user_id: user.id, property_id: property&.id }) if defined?(Sentry)
    end

    # Find existing User for matching Topnlab client. Critical safety rules:
    #
    # 1. Exclude soft-deleted: `User.unscoped` (default_scope filter bypass)
    #    приводил к match'у на deleted users → broken cabinet linkage.
    #    Используем `User.where(deleted_at: nil)` explicit.
    #
    # 2. Role filter: phone-last-10 collision — admin/agent users могут иметь
    #    placeholder phones (+79991234567 etc.). Без role-filter sync будет
    #    линковать Property к admin User вместо нового client. Ограничиваем
    #    phone-lookup до `role IN (client, agent)`. Email-match безопаснее —
    #    real клиент не должен иметь admin@ email, но даже там фильтруем.
    def find_existing_user(email, phone)
      scope = User.where(deleted_at: nil, active: true)
      if email.present?
        user = scope.find_by('LOWER(email) = ?', email.downcase)
        return user if user
      end
      if phone.present?
        digits = phone.gsub(/\D/, '').last(10)
        return nil if digits.length < 10
        # Phone match — только среди real clients/agents, не admin'ов.
        return scope.where(role: %i[client agent])
                    .where('phone LIKE ?', "%#{digits}").first
      end
      nil
    end

    def build_user_attrs(data, email, phone)
      first_name  = data['firstname'].to_s.strip.presence || 'Клиент'
      last_name   = data['lastname'].to_s.strip.presence  || '—'
      middle_name = data['fathername'].to_s.strip.presence

      attrs = {
        first_name:  first_name,
        last_name:   last_name,
        middle_name: middle_name,
        role:        :client,
        active:      true,
        password:    SecureRandom.urlsafe_base64(32),
        crm_synced_at: Time.current
      }
      # Store Topnlab client id in crm_user_id so future staff syncs can
      # cross-reference (Topnlab client ids are in a separate namespace from
      # staff user ids, but the column serves as the CRM linkage for clients too).
      crm_id = data['id'].to_i
      attrs[:crm_user_id] = crm_id if crm_id.positive?
      attrs[:email] = email if email.present?
      attrs[:phone] = normalize_phone(phone) if phone.present?
      attrs
    end

    # clients/get-by-entity returns emails as an array of objects:
    #   [{"value": "foo@bar.ru", "is_main": 1}, ...]
    # or as a plain string in some older accounts.
    def extract_email(data)
      raw = data['emails'] || data['email']
      case raw
      when Array
        main = raw.find { |e| e.is_a?(Hash) && (e['is_main'].to_i == 1) } || raw.first
        main.is_a?(Hash) ? main['value'].to_s.strip.downcase.presence : main.to_s.strip.downcase.presence
      when String
        raw.strip.downcase.presence
      end
    end

    # phones similarly: [{"value": "79001234567", "is_main": 1}, ...] or String
    def extract_phone(data)
      raw = data['phones'] || data['phone']
      case raw
      when Array
        main = raw.find { |p| p.is_a?(Hash) && (p['is_main'].to_i == 1) } || raw.first
        main.is_a?(Hash) ? main['value'].to_s.strip.presence : main.to_s.strip.presence
      when String
        raw.strip.presence
      end
    end

    def normalize_phone(raw)
      digits = raw.to_s.gsub(/\D/, '')
      return nil if digits.empty?
      digits.start_with?('7', '8') ? "+7#{digits[-10..]}" : "+#{digits}"
    end
  end
end
