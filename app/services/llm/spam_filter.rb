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
      if SpamBlockedEntry.ip_blocked?(ip)
        # ссылки фиксируем до тихого дропа: suspect от спам-IP — это
        # подтверждение (issue #219: связка с IP из ipsum повышает карантин)
        promote_suspects_from(text)
        return Result.new(action: :drop, reason: :spam_ip)
      end

      urls = Llm::SpamUrls.extract(text).filter_map { |raw| Llm::SpamUrls.normalize(raw) }
      return Result.new(action: :pass) if urls.empty?

      heuristic = heuristic_hit?(text, urls)
      blocked = []

      urls.each do |url|
        entry = SpamBlockedEntry.find_block_for(host: url[:host], path: url[:path])
        if entry&.status_blocked?
          blocked << entry
          next
        end
        # hit считаем ровно раз: при эвристике карантин учтёт срабатывание
        # сам, без эвристики — учитываем найденную suspect-запись напрямую
        if heuristic
          quarantine(url, ip: ip, visitor_token: visitor_token)
        elsif entry
          SpamBlockedEntry.record_hit!(entry, ip: ip, visitor_token: visitor_token)
        end
      end

      return Result.new(action: :drop, reason: :spam_link, matches: blocked) if blocked.any?

      Result.new(action: :pass)
    end

    # suspect-записи (домен и точный URL) из сообщения от спам-IP повышаем
    # до blocked без LLM и без ответа отправителю
    def promote_suspects_from(text)
      urls = Llm::SpamUrls.extract(text).filter_map { |raw| Llm::SpamUrls.normalize(raw) }
      return if urls.empty?

      now = Time.current
      urls.each do |url|
        SpamBlockedEntry.where(entry_type: :domain, value: url[:host], status: :suspect)
                        .update_all(status: 'blocked', blocked_at: now, updated_at: now)
        next if url[:path].blank?

        SpamBlockedEntry.where(entry_type: :url, value: "#{url[:host]}#{url[:path]}", status: :suspect)
                        .update_all(status: 'blocked', blocked_at: now, updated_at: now)
      end
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
    def quarantine(url, ip:, visitor_token: nil)
      host = url[:host]
      return if host.blank?

      known = SpamAllowlistEntry.allowlisted?(host) ||
              SpamBlockedEntry.exists?(entry_type: :domain, value: host)
      if known
        if url[:path].blank?
          # класть в карантин нечего, но срабатывание эвристики учитываем:
          # иначе кворум по IP не набирался бы для pathless-ссылок
          entry = SpamBlockedEntry.find_by(entry_type: :domain, value: host)
          SpamBlockedEntry.record_hit!(entry, ip: ip, visitor_token: visitor_token)
          return
        end

        upsert_suspect(:url, "#{host}#{url[:path]}", ip: ip, visitor_token: visitor_token)
      else
        upsert_suspect(:domain, host, ip: ip, visitor_token: visitor_token)
      end
    end

    # create_or_find_by: параллельные запросы по новому домену иначе гонятся
    # в find_or_create (оба проходят find → RecordNotUnique на индексе → 500).
    def upsert_suspect(entry_type, value, ip:, visitor_token: nil)
      entry = SpamBlockedEntry.unscoped.create_or_find_by!(entry_type: entry_type, value: value) do |e|
        e.status = :suspect
        e.source = 'local'
      end
      if entry.deleted_at? # возвращается из карантина — реанимируем как local-suspect
        entry.update_columns(deleted_at: nil, status: 'suspect', source: 'local',
                             blocked_at: nil, updated_at: Time.current)
        entry.reload
      end
      SpamBlockedEntry.record_hit!(entry, ip: ip, visitor_token: visitor_token)
    end
  end
end
