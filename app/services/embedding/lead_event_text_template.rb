# frozen_string_literal: true

module Embedding
  # Phase 16.6 — text template для embed'инга LeadEvent в gemini-embedding-001.
  #
  # Включаем (важно для semantic match):
  #   • name (имя клиента)
  #   • source (откуда лид — site_form / tg_dm / etc)
  #   • topic (apartments / houses / etc) — текстом
  #   • stage (русское обозначение)
  #   • summary (свободный текст из intake'а)
  #   • notes — последние 5, объединённые
  #
  # ИСКЛЮЧАЕМ:
  #   • phone, email — PII, не помогает semantic search
  #   • crm_id, internal numbers — noise
  #   • timestamps, IDs — semantics, не fingerprint
  #
  # Truncate 2000 chars — gemini-embedding-001 принимает гораздо больше,
  # но для semantic search больше 2000 chars текста = разбавляет signal.
  module LeadEventTextTemplate
    STAGE_LABELS = {
      'new'           => 'новый лид',
      'first_contact' => 'первый контакт состоялся',
      'show'          => 'показ объекта',
      'contract'      => 'договор согласован',
      'deal'          => 'сделка идёт',
      'closed_won'    => 'сделка выиграна',
      'closed_lost'   => 'сделка проиграна'
    }.freeze

    def self.build(lead_event)
      meta = lead_event.metadata || {}

      parts = []
      parts << "Имя клиента: #{meta['name']}" if meta['name'].present?
      parts << "Источник: #{lead_event.source}"
      parts << "Стадия: #{STAGE_LABELS[lead_event.current_stage] || lead_event.current_stage}"

      topic_title = topic_label(lead_event.anchor_topic_key)
      parts << "Топик: #{topic_title}" if topic_title.present?

      parts << "Описание: #{meta['summary']}" if meta['summary'].present?

      if meta['notes'].is_a?(Array) && meta['notes'].any?
        recent_notes = meta['notes'].last(5).map { |n| n.is_a?(Hash) ? n['text'].to_s : n.to_s }.compact_blank
        parts << "Заметки: #{recent_notes.join(' | ')}" if recent_notes.any?
      end

      parts.join("\n").truncate(2000)
    end

    def self.topic_label(key)
      return nil if key.blank?

      ::Telegram::TopicRegistry.title(key)
    rescue StandardError
      nil
    end
  end
end
