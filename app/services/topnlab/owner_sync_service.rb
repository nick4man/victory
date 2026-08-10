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
        # Общая логика с телеграм-сбором собственника: правила нормализации
        # телефона и поиска дубля обязаны совпадать, иначе один человек,
        # пришедший разными путями, заведётся дважды.
        user, was_created = Crm::OwnerLinker.from_topnlab(client_data)

        if user
          Crm::OwnerLinker.attach!(property, user)
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

    # D3 — Send «вам привязан объект» invitation через channels: %i[email tg].
    # SMS НАМЕРЕННО отключён — после #413f phone-only клиенты активируются
    # одним из двух путей:
    #   1. Inbound trigger: клиент сам пишет @anvictorybot (sales script /
    #      QR / email-подпись агента) → ActivationRequestProcessor.
    #   2. Admin-shared link: агент в /admin/users генерирует QR/URL
    #      и делится с клиентом через любой канал (WhatsApp / в офисе /
    #      email / печать).
    #
    # SMS-fallback в CabinetInvitationDispatcher остаётся в коде, но
    # доступен ТОЛЬКО как admin-triggered action (не реализован в этом
    # commit'е — defer). Auto-sync больше не жжёт SMS на phone-only.
    #
    # См. `app/services/cabinet_invitation_dispatcher.rb` для idempotency.
    def send_cabinet_invitation(user, property)
      return unless user.respond_to?(:invited_at)

      CabinetInvitationDispatcher.call(user, property, channels: %i[email tg])
    rescue StandardError => e
      Rails.logger.warn("[OwnerSync] invitation failed user=#{user.id}: #{e.class}: #{e.message}")
      Sentry.capture_exception(e, extra: { user_id: user.id, property_id: property&.id }) if defined?(Sentry)
    end
  end
end
