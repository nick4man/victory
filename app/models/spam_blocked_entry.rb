# frozen_string_literal: true

# Запись блок-листа (см. миграцию CreateSpamBlocklist). value хранится только
# в нормализованном виде (Llm::SpamUrls.normalize): иначе IDN-омографы
# (sberbаnk.ru с русской «а») обходят проверку другим написанием того же
# домена. Уникальность и все поиски — по value_digest (SHA-256): value
# текстом может достигать ~5 КБ (URL phishing-фидов), а B-tree PG выше
# ~2700 байт на ключ не индексирует.
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

  before_validation :assign_value_digest

  # Единый ключ поиска/уникальности; nil-value (валидация отсекает раньше)
  # сводится в дайджест пустой строки — колонка NOT NULL.
  def self.digest_for(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  # Точное совпадение + CIDR-подсети из firehol-фидов (botscout отдаёт
  # и /31). Точный fast-path — индексом по digest; подсетей мало, их
  # список кешируется.
  def self.ip_blocked?(ip)
    return false if ip.blank?

    addr = IPAddr.new(ip.to_s) # InvalidAddressError на мусоре
    return true if status_blocked.entry_type_ip.where(value_digest: digest_for(ip)).exists?

    cidrs = Rails.cache.fetch(CIDR_CACHE_KEY, expires_in: CIDR_CACHE_TTL) do
      status_blocked.entry_type_ip.where('value LIKE ?', '%/%').pluck(:value)
    end
    cidrs.any? { |cidr| IPAddr.new(cidr).include?(addr) }
  rescue IPAddr::InvalidAddressError
    false
  end

  # Приоритеты: url-level blocked бьёт всегда (точный путь, даже на белом
  # домене); доменный blocked — любым путём, но allowlist (Tranco Top-10k)
  # его снимает; suspect-запись никогда не маскирует blocked-домен.
  def self.find_block_for(host:, path: nil)
    return nil if host.blank?

    url_entry = path.present? ? find_by(entry_type: :url, value_digest: digest_for("#{host}#{path}")) : nil
    domain_entry = find_by(entry_type: :domain, value_digest: digest_for(host))

    return url_entry if url_entry&.status_blocked?
    if domain_entry&.status_blocked?
      return nil if SpamAllowlistEntry.allowlisted?(host)
      return domain_entry
    end

    url_entry || domain_entry
  end

  # Подсчёт срабатывания suspect-записи. Кворум — не меньше QUORUM
  # РАЗНЫХ IP за HIT_WINDOW: visitor-cookie спамер сбрасывает одним кликом,
  # поэтому токен как мера независимости бессмысленен (один IP + три сменных
  # токена = один спамер, а не три подтверждения). Переводит в blocked только
  # ЛОКАЛЬНУЮ запись (source = local); служебные записи фидов (шортенеры)
  # hits'ами не автоблокируются — их статусом управляет только синк фидов.
  def self.record_hit!(entry, ip:, visitor_token: nil)
    return if entry.blank? || (ip.blank? && visitor_token.blank?)

    entry.with_lock do
      entry.reload
      now = Time.current
      tokens = Array(entry.hit_tokens).select { |t| (now - Time.iso8601(t['at'])) < HIT_WINDOW }
      unless tokens.any? { |t| t['ip'] == ip.to_s && t['vt'].to_s == visitor_token.to_s }
        tokens << { 'ip' => ip.to_s, 'vt' => visitor_token.to_s, 'at' => now.iso8601 }
      end

      attrs = {
        hits:        entry.hits.to_i + 1,
        hit_tokens:  tokens.last(HIT_KEYS_CAP),
        last_hit_at: now
      }
      distinct_ips = tokens.map { |t| t['ip'] }.reject(&:blank?).uniq
      local_quorum = entry.source == 'local' && entry.status_suspect? && distinct_ips.size >= QUORUM
      if local_quorum
        attrs[:status] = :blocked
        attrs[:blocked_at] = now
      end
      entry.update_columns(attrs)
    end
  end

  # Ручная пометка URL/домена как спама (issue #219, модерация через
  # /admin/spam_blocked_entries). Нормализация та же, что у фильтра: запись
  # и проверка обязаны встречаться на одном ключе, иначе ручной бан
  # обходится написанием с www/IDN/портом. Источник записи принудительно
  # local: фидовая запись, выпавшая из фида, протухла бы вместе с ручной
  # пометкой (retire_stale владеет только своими источниками), а так бан
  # держится, пока его самим не снимут; синк при этом по-прежнему свежит
  # seen_at ключа и повышает статус подтверждённым фидом.
  def self.block_locally!(raw, status: :blocked)
    url = Llm::SpamUrls.normalize(raw)
    return { ok: false, error: :invalid_url } unless url

    status = status.to_s
    return { ok: false, error: :invalid_status } unless statuses.key?(status)

    entry_type, value = if url[:path].present?
                          [:url, "#{url[:host]}#{url[:path]}"]
                        else
                          [:domain, url[:host]]
                        end

    entry = unscoped.create_or_find_by!(entry_type: entry_type, value_digest: digest_for(value)) do |e|
      e.value = value
      e.status = status
      e.source = 'local'
      e.blocked_at = Time.current if status == 'blocked'
    end
    # существующая запись (фидовая/удалённая/иного статуса) перезаписывается:
    # человек знает точнее фида и карантина
    unless !entry.deleted_at? && entry.source == 'local' && entry.status == status
      entry.update_columns(deleted_at: nil, status: status, source: 'local',
                           blocked_at: status == 'blocked' ? Time.current : nil,
                           updated_at: Time.current)
      entry.reload
    end
    { ok: true, value: entry }
  end

  private

  def assign_value_digest
    self.value_digest = self.class.digest_for(value)
  end
end
