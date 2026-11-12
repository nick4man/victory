# frozen_string_literal: true

# Запись блок-листа (см. миграцию CreateSpamBlocklist). value хранится только
# в нормализованном виде (Llm::SpamUrls.normalize): иначе IDN-омографы
# (sberbаnk.ru с русской «а») обходят проверку другим написанием того же
# домена.
class SpamBlockedEntry < ApplicationRecord
  # suspect → blocked, если домен прилетел от стольких разных сессий/IP
  # за окно: один спамер ≠ повод блочить, три независимых — повод.
  QUORUM = 3
  HIT_WINDOW = 24.hours
  HIT_KEYS_CAP = 20 # верхняя граница hit_tokens, чтобы jsonb не разрастался

  enum :entry_type, { domain: 'domain', url: 'url', ip: 'ip' }, prefix: true
  enum :status, { suspect: 'suspect', blocked: 'blocked' }, prefix: true

  default_scope { not_deleted }
  scope :not_deleted, -> { where(deleted_at: nil) }

  validates :value, presence: true

  def self.ip_blocked?(ip)
    ip.present? && status_blocked.entry_type_ip.exists?(value: ip.to_s)
  end

  # URL-уровень точнее доменного: t.me/spam_channel бьёт раньше, чем t.me.
  def self.find_block_for(host:, path: nil)
    return nil if host.blank?

    if path.present?
      hit = find_by(entry_type: :url, value: "#{host}#{path}")
      return hit if hit
    end
    find_by(entry_type: :domain, value: host)
  end

  # Подсчёт срабатывания suspect-записи. Кворум разных ключей (visitor_token,
  # при его отсутствии — IP) за HIT_WINDOW переводит запись в blocked.
  def self.record_hit!(entry, key:)
    return if entry.blank? || key.blank?

    now = Time.current
    tokens = Array(entry.hit_tokens).select { |t| (now - Time.iso8601(t['at'])) < HIT_WINDOW }
    tokens << { 'key' => key.to_s, 'at' => now.iso8601 } if tokens.none? { |t| t['key'] == key.to_s }

    attrs = {
      hits:       entry.hits.to_i + 1,
      hit_tokens: tokens.last(HIT_KEYS_CAP),
      last_hit_at: now
    }
    if entry.status_suspect? && tokens.map { |t| t['key'] }.uniq.size >= QUORUM
      attrs[:status] = :blocked
      attrs[:blocked_at] = now
    end
    entry.update_columns(attrs)
  end
end
