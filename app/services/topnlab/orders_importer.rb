# frozen_string_literal: true

# Pulls Topnlab type=order entities (Покупатели/Арендаторы) into BuyerOrder.
# Iterates (action × realty_type) matrix; respects the 6s rate limit on get-ids.
module Topnlab
  class OrdersImporter
    REALTY_TYPES = %w[flat room house land commerce garage].freeze
    ACTIONS      = %w[sale rent].freeze
    ACTIVE_STATES = %w[lead active ad prepayment deferred].freeze

    def initialize(client: Topnlab::Client.new)
      @client = client
    end

    def call
      agents_index = build_agents_index
      total_ids = 0
      total_upserted = 0
      seen_ids = []
      errors = []

      # Topnlab `type=order` does NOT respect realty_type filter (verified empirically),
      # so we fetch by action only and infer realty_type from `object_type` payload field.
      ACTIONS.each do |action|
        ids = safe_get_ids(action: action, errors: errors)
        total_ids += ids.size
        next if ids.empty?

        ids.each_slice(100) do |chunk|
          # get_entities сам бросает на не-Hash (см. Client#get_entities) —
          # ошибка уйдёт в `errors` через rescue ниже и заблокирует archive.
          entities = @client.get_entities(chunk, type: 'order', append: 'stages')

          entities.each_value do |payload|
            attrs = Topnlab::OrderMapper.new(payload, agents_index).to_attributes
            next unless attrs

            record = BuyerOrder.find_or_initialize_by(crm_id: attrs[:crm_id])
            record.assign_attributes(attrs)
            if record.save
              total_upserted += 1
              seen_ids << record.id
            else
              errors << "id=#{attrs[:crm_id]}: #{record.errors.full_messages.join(', ')}"
            end
          end
        end
      rescue Topnlab::Client::Error => e
        errors << "#{action}: #{e.message}"
      end

      # Тот же инвариант, что и в Importer#archive_missing: архивируем только
      # после ПОЛНОГО обхода. Раньше archive шёл безусловно — один битый ответ
      # CRM отправлял все активные BuyerOrder (их ~950) в архив.
      archived =
        if errors.any?
          Rails.logger.warn("[OrdersImporter] #{errors.size} ошибок — обход неполный, archive пропущен")
          0
        elsif seen_ids.empty?
          Rails.logger.error('[OrdersImporter] seen_ids пуст — archive отменён (защита от массовой архивации)')
          0
        else
          BuyerOrder.where.not(id: seen_ids).where(deal_state: ACTIVE_STATES).update_all(deal_state: 'archive')
        end

      { success: errors.empty?, ids_seen: total_ids, upserted: total_upserted, archived: archived, errors: errors }
    end

    private

    # Ошибка регистрируется в `errors`, а не глотается: иначе сбой fetch'а
    # деградировал в «заказов нет» и разблокировал массовую архивацию.
    def safe_get_ids(action:, errors:)
      Array(@client.get_ids(type: 'order', action: action))
    rescue Topnlab::Client::Error => e
      Rails.logger.warn("[OrdersImporter] get_ids #{action} failed: #{e.message}")
      errors << "#{action} get_ids: #{e.message}"
      []
    end

    def build_agents_index
      User.synced_from_crm.pluck(:email, :id).to_h { |email, id| [email.to_s.downcase, id] }
    end
  end
end
