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
  HIT_KEYS_CAP = 20    # верхняя граница hit_tokens, чтобы jsonb не разрастался
  CIDR_CACHE_KEY = 'spam_blocked_cidrs'
  CIDR_CACHE_TTL = 1.hour

  # entry_type: domain — домен (блок любого пути) | url — полный host+path | ip — адрес/подсеть
  # status: suspect — карантин (учёт hits) | blocked — блок
  enum :entry_type, { domain: 'domain', url: 'url', ip: 'ip' }, prefix: true
  enum :status, { suspect: 'suspect', blocked: 'blocked' }, prefix: true

  default_scope { not_deleted }
  scope :not_deleted, -> { where(deleted_at: nil) }

  validates :value, presence: true

  # Точное совпадение + CIDR-подсети из firehol-фидов (botscout отдаёт
  # и /31). Точный fast-path — индексом; подсетей мало, их список кешируется.
  def self.ip_blocked?(ip)
    return false if ip.blank?

    addr = IPAddr.new(ip.to_s) # InvalidAddressError на мусоре
    return true if status_blocked.entry_type_ip.where(value: ip.to_s).exists?

    cidrs = Rails.cache.fetch(CIDR_CACHE_KEY, expires_in: CIDR_CACHE_TTL) do
      status_blocked.entry_type_ip.where('value LIKE ?', '%/%').pluck(:value)
    end
    cidrs.any? { |cidr| IPAddr.new(cidr).include?(addr) }
  rescue IPAddr::InvalidAddressError
    false
  end

  # Приоритеты: url-level blocked бьёт всегда (точный путь, даже на белом
  # домене); доменный blocked — любым путём, но allowlist (Umbrella Top-10k)
  # его снимает; suspect-запись никогда не маскирует blocked-домен.
  def self.find_block_for(host:, path: nil)
    return nil if host.blank?

    url_entry = path.present? ? find_by(entry_type: :url, value: "#{host}#{path}") : nil
    domain_entry = find_by(entry_type: :domain, value: host)

    return url_entry if url_entry&.status_blocked?
    if domain_entry&.status_blocked?
      return nil if SpamAllowlistEntry.allowlisted?(host)
      return domain_entry
    end

    url_entry || domain_entry
  end

  # Подсчёт срабатывания suspect-записи. Кворум разных ключей (visitor_token,
  # при его отсутствии — IP) за HIT_WINDOW переводит ЛОКАЛЬНУЮ запись
  # (source = local) в blocked. Служебные записи фидов (шортенеры) hits'ами
  # не автоблокируются — их статусом управляет только синк фидов.
  def self.record_hit!(entry, key:)
    return if entry.blank? || key.blank?

    entry.with_lock do
      entry.reload
      now = Time.current
      tokens = Array(entry.hit_tokens).select { |t| (now - Time.iso8601(t['at'])) < HIT_WINDOW }
      tokens << { 'key' => key.to_s, 'at' => now.iso8601 } if tokens.none? { |t| t['key'] == key.to_s }

      attrs = {
        hits:        entry.hits.to_i + 1,
        hit_tokens:  tokens.last(HIT_KEYS_CAP),
        last_hit_at: now
      }
      local_quorum = entry.source == 'local' && entry.status_suspect? &&
                     tokens.map { |t| t['key'] }.uniq.size >= QUORUM
      if local_quorum
        attrs[:status] = :blocked
        attrs[:blocked_at] = now
      end
      entry.update_columns(attrs)
    end
  end
end
