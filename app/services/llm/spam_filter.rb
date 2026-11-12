# frozen_string_literal: true

module Llm
  # Антиспам-фильтр чат-бота перед вызовом LLM (issue #219). Два слоя:
  #
  #   1. IP-репутация (ipsum/firehol) → тихий дроп, без LLM и без ответа.
  #   2. Доменные списки: blocked → дроп; suspect → hit и сообщение проходит;
  #      эвристики (стоп-слова, hxxp, шортенеры) → новый домен в карантин.
  #
  # Карантин vs блок: неизвестный домен от эвристик получает status suspect,
  # мгновенного бана нет. Кворум hits от разных сессий/IP (SpamBlockedEntry)
  # переводит его в blocked — новые спам-домены режутся без деплоя.
  module SpamFilter
    STOP_WORDS = [
      'продвижение ботов', 'продвижение сайтов', 'seo-продвижение', 'раскрутк',
      'накрутк', 'купить подписчик', 'подписчиков', 'спам-рассылк',
      'рассылка по баз', 'ставки на спорт', 'букмекер', 'казино',
      '1win', '1xbet', 'виагр', 'кредит без справок',
      'заработок в интернете', 'пассивный доход', 'вывод денег'
    ].freeze

    Result = Struct.new(:action, :reason, :matches, keyword_init: true)

    module_function

    # @return [Result] action: :drop | :pass; reason: :spam_ip | :spam_link
    def classify(text, ip:, visitor_token:)
      return Result.new(action: :drop, reason: :spam_ip) if SpamBlockedEntry.ip_blocked?(ip)

      urls = Llm::SpamUrls.extract(text).filter_map { |raw| Llm::SpamUrls.normalize(raw) }
      return Result.new(action: :pass) if urls.empty?

      key = visitor_token.presence || ip.to_s
      heuristic = heuristic_hit?(text, urls)
      blocked = []

      urls.each do |url|
        entry = SpamBlockedEntry.find_block_for(host: url[:host], path: url[:path])
        if entry&.status_blocked?
          blocked << entry
          next
        end
        SpamBlockedEntry.record_hit!(entry, key: key) if entry
        quarantine(url, key: key) if heuristic
      end

      return Result.new(action: :drop, reason: :spam_link, matches: blocked) if blocked.any?

      Result.new(action: :pass)
    end

    # Эвристические признаки спама вокруг ссылок: стоп-слова, обфускация
    # схемы (hxxp), шортенеры из hagezi-фида (спамеры прячут домены).
    def heuristic_hit?(text, urls)
      t = text.to_s.downcase
      return true if STOP_WORDS.any? { |w| t.include?(w) }
      return true if %r{hxxps?://}i.match?(t)

      hosts = urls.map { |u| u[:host] }
      SpamBlockedEntry.entry_type_domain.where(source: 'hagezi_shorteners', value: hosts).exists?
    end

    # Новый домен от эвристик → карантин (suspect), не мгновентный бан.
    # Белый (allowlist) или уже известный домень блочим только на уровне
    # пути: t.me — ок, t.me/spam_channel — suspect-запись url-уровня.
    # Домен без пути в этих случаях не трогаем — иначе самострел
    # по легитимным клиентам.
    def quarantine(url, key:)
      host = url[:host]
      return if host.blank?

      known = SpamAllowlistEntry.allowlisted?(host) ||
              SpamBlockedEntry.exists?(entry_type: :domain, value: host)
      if known
        return if url[:path].blank?

        upsert_suspect(:url, "#{host}#{url[:path]}", key)
      else
        upsert_suspect(:domain, host, key)
      end
    end

    def upsert_suspect(entry_type, value, key)
      entry = SpamBlockedEntry.find_or_create_by!(entry_type: entry_type, value: value) do |e|
        e.status = :suspect
        e.source = 'local'
      end
      SpamBlockedEntry.record_hit!(entry, key: key)
    end
  end
end
