# frozen_string_literal: true

module Avito
  # Parses an inbound Avito Messenger webhook V3 payload and routes the message
  # to the configured target channel (Telegram by default).
  #
  # We intentionally do as little work synchronously as the webhook HTTP handler:
  # ack quickly, enqueue the processor, and let Sidekiq handle retries. This
  # processor is the worker-side entry point.
  class InboundProcessor
    def initialize(payload)
      @payload = payload.is_a?(Hash) ? payload : parse_payload(payload)
    end

    def call
      value = extract_message_value
      return :ignored if value.blank?

      message_id = value['id'].to_s
      return :ignored if message_id.blank?

      message = persist_or_find_message(message_id, value)
      return :duplicate if message.blank?

      return :ignored unless message_incoming?(message)

      route_message(message)
      :routed
    rescue StandardError => e
      Rails.logger.error("[Avito::InboundProcessor] #{e.class}: #{e.message}")
      raise
    end

    private

    def parse_payload(raw)
      return {} if raw.blank?

      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      {}
    end

    def extract_message_value
      @payload.dig('payload', 'value')
    end

    def persist_or_find_message(message_id, value)
      AvitoMessage.create!(message_attributes(message_id, value))
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise unless duplicate_error?(e)

      existing = AvitoMessage.find_by(message_id: message_id)
      return nil if existing.nil? || existing.routed_at.present?

      existing
    end

    def message_attributes(message_id, value)
      item_id = value['item_id']

      {
        message_id:   message_id,
        chat_id:      value['chat_id'].to_s,
        author_id:    value['author_id'].to_i,
        user_id:      value['user_id'].to_i,
        item_id:      item_id,
        property:     resolve_property(item_id),
        content_type: value['type'].to_s,
        content_text: extract_text(value),
        payload:      value,
        direction:    direction_from(value)
      }
    end

    def duplicate_error?(error)
      if error.is_a?(ActiveRecord::RecordInvalid)
        error.record.errors.of_kind?(:message_id, :taken)
      else
        true
      end
    end

    def resolve_property(item_id)
      return nil if item_id.blank?

      Property.find_by(external_source: 'avito', external_id: item_id.to_s)
    end

    def extract_text(value)
      value.dig('content', 'text').to_s.strip.presence
    end

    def direction_from(value)
      # user_id is the Avito account that owns the webhook; messages from that
      # account are outgoing (we wrote them), everything else is incoming.
      value['author_id'].to_i == value['user_id'].to_i ? 'outgoing' : 'incoming'
    end

    def message_incoming?(message)
      message.direction_incoming?
    end

    def route_message(message)
      ChannelRouter.new(message).call
      record_ack(message.message_id)
    end

    def record_ack(message_id)
      AvitoWebhookAck.create!(message_id: message_id, processed_at: Time.current)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      raise unless e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:message_id, :taken)

      Rails.logger.info("[Avito::InboundProcessor] ack already exists for message_id=#{message_id}")
    end
  end
end
