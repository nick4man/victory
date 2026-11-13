# frozen_string_literal: true

module Llm
  module SpamFeeds
    # Ежесуточный cron-синк антиспам-фидов (issue #219, задача в
    # config/sidekiq_cron.yml — spam_feeds_sync). Источники:
    #
    #   домены   — hagezi TIF/Fake (adblock-формат ||domain^), matomo
    #              referrer-spam, Phishing.Database (домены + полные URL);
    #   URL      — Phishing.Database phishing-links, URLhaus (полные URL);
    #   IP       — stamparm/ipsum level 3, firehol cleantalk/stopforumspam/
    #              botscout 7d (включая CIDR-подсети);
    #   allowlist — Tranco Top-1M (официальный zip), верхние 10k — защита
    #              от самострела локальных эвристик.
    #
    # Память ограничена чанками BATCH: ответ фида парсится в два прохода
    # (счётчик для min_rows, затем пакетная запись), таблица в ActiveRecord-
    # объекты не материализуется — upsert/реанимация/протухание идут
    # set-based запросами, свежесть ключа помечается seen_at. После удачной
    # выгрузки записи источника, не виданные в этом прогоне, протухают
    # (soft-delete): иначе выбывший из списков IP/домен блочился бы вечно.
    # Сбой/пустой/усечённый фид список не стирает. source = local синк не
    # трогает (кроме повышения статуса suspect → blocked подтверждённым
    # доверенным фидом).
    class SyncJob < ApplicationJob
      queue_as :low_priority

      BATCH = 1_000
      # живой phishing-links — ~800k строк; сверх ~100 МБ ответ не принимаем,
      # чтобы ежедневный job не улетал в OOM на обрезках/гигантах
      MAX_BODY_BYTES = 100.megabytes

      # min_rows — порог правдоподобия выгрузки: непустой, но резко усечённый
      # ответ (HTTP 200 с обрезком списка) не должен стирать боевой список.
      DOMAIN_FEEDS = {
        'hagezi_tif'        => { url: 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt',
                                 format: :adblock, min_rows: 50_000 },
        'hagezi_fake'       => { url: 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/fake.txt',
                                 format: :adblock, min_rows: 1_000 },
        # шортенеры сами по себе не блок — только повод для эвристики
        'hagezi_shorteners' => { url: 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/urlshortener.txt',
                                 format: :adblock, status: :suspect, min_rows: 100 },
        'matomo_spammers'   => { url: 'https://raw.githubusercontent.com/matomo-org/referrer-spam-list/master/spammers.txt',
                                 format: :plain, min_rows: 100 },
        'phishing_domains'  => { url: 'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-domains-ACTIVE.txt',
                                 format: :plain, min_rows: 1_000 },
        # полные URL: блок одной страницы, не всего хоста
        'phishing_links'    => { url: 'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-links-ACTIVE.txt',
                                 format: :urls, entry_type: :url, min_rows: 1_000 }
      }.freeze
      # URLhaus: keyless-экспорты abuse.ch отдают 410 — нужен бесплатный
      # Auth-Key (auth.abuse.ch), URL с ключом кладётся в ENV; без ключа фид
      # пропускается, остальные источники работают
      URLHAUS_FEED = {
        'urlhaus'           => { url: ENV.fetch('URLHAUS_EXPORT_URL', ''),
                                 format: :urls, entry_type: :url, min_rows: 1_000 }
      }.freeze
      IP_FEEDS = {
        'ipsum_l3'              => { url: 'https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt',
                                     min_rows: 1_000 },
        'firehol_cleantalk'     => { url: 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/cleantalk_7d.ipset',
                                     min_rows: 1_000 },
        'firehol_stopforumspam' => { url: 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/stopforumspam_7d.ipset',
                                     min_rows: 100 },
        'firehol_botscout'      => { url: 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/botscout_7d.ipset',
                                     min_rows: 100 }
      }.freeze
      # Tranco Top-1M: стартовый URL отдаётся только zip'ом и отвечает 307
      # на /download/daily/… — fetch следует редиректам вручную
      # (faraday-follow_redirects в проекте нет); распаковка — Llm::SpamFeeds::Zip
      # (без rubyzip). Первые 10k строк — домены, которые локальные
      # эвристики не имеют права блочить на уровне корня.
      ALLOWLIST_URL = 'https://tranco-list.eu/top-1m.csv.zip'
      ALLOWLIST_TOP = 10_000
      # усечённая выгрузка не должна стирать рабочий allowlist целиком
      ALLOWLIST_MIN_ROWS = 9_000
      # сколько редиректов готовы пройти за один вызов fetch
      MAX_REDIRECTS = 3

      def perform
        run_at = Time.current
        stats = {}
        # entry_type => источники, чья выгрузка в этом прогоне полностью
        # успешна (публикуется import_feed только после полного прохода)
        synced = Hash.new { |h, k| h[k] = [] }

        (DOMAIN_FEEDS.merge(URLHAUS_FEED)).each do |source, cfg|
          stats[source] = import_feed(source, cfg, run_at, synced)
        end
        IP_FEEDS.each do |source, cfg|
          stats[source] = import_feed(source, cfg.merge(entry_type: :ip), run_at, synced)
        end

        # источники публикуются на каждом чанке — перед протуханием сжимаем,
        # иначе retire_stale уходил бы с сотнями дублей в IN (...) большого фида
        synced.each_value(&:uniq!)
        retire_stale(synced, run_at)
        downgrade_unconfirmed_blocked(synced, run_at)
        # протухание могло увести в soft-delete CIDR-подсети — кеш ip_blocked?
        # иначе продолжал бы дропать адреса до часа (CIDR_CACHE_TTL)
        Rails.cache.delete(SpamBlockedEntry::CIDR_CACHE_KEY)
        stats['tranco_allowlist'] = sync_allowlist
        Rails.logger.info("[SpamFeeds] синк завершён: #{stats.inspect}")
        stats
      end

      private

      # Одна выгрузка: два прохода по телу (подсчёт для min_rows, затем
      # пакетная запись), чтобы в памяти жил только чанк BATCH строк.
      # Возвращает число записей фида; 0 — фид не синкнулся (нет URL, пустой,
      # битый, усечённый), тогда прежние записи источника не протухают.
      def import_feed(source, cfg, run_at, synced)
        if cfg[:url].blank?
          Rails.logger.warn("[SpamFeeds] #{source}: URL не задан — фид пропущен")
          return 0
        end

        body = fetch(cfg[:url])
        return 0 if body.nil?

        status = cfg[:status] || :blocked
        total = count_valid_tokens(body, cfg)
        if total < cfg[:min_rows]
          Rails.logger.warn("[SpamFeeds] #{source}: подозрительно мало записей " \
                            "(#{total} < #{cfg[:min_rows]}) — выгрузка отклонена")
          body.close!
          return 0
        end

        body.rewind
        # типы накапливаем в локальный аккумулятор и публикуем в synced
        # только после полного успешного прохода: иначе падение середины
        # импорта оставило бы источник в synced, и retire_stale стёр бы
        # записи необработанной части фида (контракт: сбой список не стирает)
        feed_synced = Hash.new { |h, k| h[k] = [] }
        import_batches(body, source, cfg, status, run_at, feed_synced)
        feed_synced.each { |type, sources| synced[type].concat(sources) }
        total
      rescue StandardError => e
        # сообщение об ошибке намеренно не логируем: в нём может оказаться
        # URLHAUS_EXPORT_URL с Auth-Key (Net::HTTP включает хост/путь в текст)
        Rails.logger.warn("[SpamFeeds] #{source}: синк не удался (#{e.class})")
        0
      ensure
        body&.close! if body && !body.closed?
      end

      # Порог min_rows считает записи, реально прошедшие нормализацию: токены,
      # отброшенные валидацией (корневые URL из URL-фида, мусор), к порогу не
      # подходят — иначе 999 бесполезных строк + 1 валидная проходили порог,
      # источник публиковался как synced, а retire_stale стирал боевой список
      # (обход защиты от усечённой выгрузки — ревью Kimi, раунд 10)
      def count_valid_tokens(body, cfg)
        count = 0
        body.each_line do |line|
          token = parse_token(line, cfg[:format] || :plain)
          next if token.blank?

          _type, key = cfg[:entry_type] == :ip ? [:ip, token] : normalize_entry(cfg.fetch(:entry_type, :domain), token)
          count += 1 if key
        end
        count
      end

      # Пакетный upsert чанками. Уникальный индекс полный (без исключения
      # soft-deleted): вернувшийся ключ сначала реанимируем, но НЕ local —
      # ручной разблок модератора синк не отменяет; новые вставляем
      # (on_conflict skip), затем set-based помечаем seen_at и повышаем
      # suspect → blocked подтверждённым фидом (в т.ч. локальную запись).
      def import_batches(body, source, cfg, status, run_at, synced)
        batch = []
        flush = -> { flush_batch(batch, source, status, run_at, synced) }

        body.each_line do |line|
          token = parse_token(line, cfg[:format] || :plain)
          next if token.blank?

          type, key = cfg[:entry_type] == :ip ? [:ip, token] : normalize_entry(cfg.fetch(:entry_type, :domain), token)
          next unless key

          batch << { entry_type: type.to_s, value: key, value_digest: SpamBlockedEntry.digest_for(key),
                     source: source, status: status.to_s,
                     seen_at: run_at, blocked_at: (run_at if status == :blocked),
                     confirmations: (status == :blocked ? { source => run_at.iso8601 } : {}),
                     created_at: run_at, updated_at: run_at }
          flush.call if batch.size >= BATCH
        end
        flush.call
      end

      # Запись чанка с группировкой по фактическому типу записей: типы
      # складываем в аккумулятор вызывающего импорта, который опубликует
      # источник в synced только после полного успешного прохода по фиду.
      # Поиск/конфликт — по value_digest (SHA-256): value текстом до ~5 КБ
      # неиндексируем B-tree PG, уникальность держит дайджест-индекс.
      # blocked_at у фидовых записей = время ПОСЛЕДНЕГО ПОДТВЕРЖДЕНИЯ
      # blocked-источником (не первичной блокировки): так понижение раунда 12
      # отличает «ключ подтверждён blocked-фидом сегодня» от «только suspect».
      def flush_batch(batch, source, status, run_at, synced)
        return if batch.empty?

        batch.group_by { |r| r[:entry_type] }.each do |type, rows|
          digests = rows.map { |r| r[:value_digest] }
          scope = SpamBlockedEntry.unscoped.where(entry_type: type, value_digest: digests)

          # local из автоматической реанимации исключаем: разблок модератора
          # синк не отменяет (контракт «local синк не трогает») — иначе домен
          # из фида, удалённый вручную, возвращался бы в блок каждую ночь
          scope.where.not(deleted_at: nil)
               .where.not(source: 'local')
               .update_all(deleted_at: nil, seen_at: run_at, updated_at: run_at)
          SpamBlockedEntry.insert_all(rows, unique_by: :idx_spam_blocked_entries_type_digest)
          if status == :blocked
            # blocked-источник подтвердил ключ: свежий blocked_at — метка для
            # downgrade_unconfirmed_blocked; confirmations[source] — метка для
            # защиты от протухания/понижения при сбое другого фида, ранее
            # подтвердившего тот же ключ (ревью Kimi, раунд 14)
            scope.update_all(seen_at: run_at, blocked_at: run_at, updated_at: run_at)
            scope.where(status: 'blocked')
                 .update_all(["confirmations = COALESCE(confirmations, '{}'::jsonb) || ?::jsonb",
                              { source => run_at.iso8601 }.to_json])
            # повышение suspect → blocked забирает и владение: иначе при
            # последующем сбое blocked-фида запись осталась бы под владельцем-
            # suspect'ом, downgrade увидел бы его в synced и понизил бы
            # подтверждённый blocked (fail-open — ревью Kimi, раунд 13).
            # local повышаем без смены владельца — контракт «local синк не
            # трогает» (кроме самого повышения статуса).
            scope.where(status: 'suspect').where.not(source: 'local')
                 .update_all(status: 'blocked', blocked_at: run_at, source: source, updated_at: run_at)
            scope.where(status: 'suspect', source: 'local')
                 .update_all(status: 'blocked', blocked_at: run_at, updated_at: run_at)
          else
            # suspect-источник не трогает blocked_at: запись остаётся
            # неподтверждённой на blocked-уровне
            scope.update_all(seen_at: run_at, updated_at: run_at)
          end
          synced[type.to_sym] << source
        end
        batch.clear
      end

      def parse_token(line, format)
        case format
        when :adblock
          # hagezi adblock: ||domain^; комментарии «!», исключения «@@||»,
          # модификаторы (...^$document) пропускаем — нужны только голые домены
          line[/\A\|\|([a-z0-9.-]+)\^\s*\z/i, 1]&.strip&.downcase
        else
          # plain/urls: комментарии «#», ключ — первый токен строки
          line.split('#').first.to_s.split.first
        end
      end

      # Доменные фиды приводим к единому виду фильтра; URL-фиды пишут только
      # полные host+path — запись без пути пропускаем (корень хоста из
      # URL-фида блочить нельзя: доменный уровень — работа доменных фидов).
      # Ведущий '*.' (wildcard-записи Phishing.Database) опускаем до домена.
      def normalize_entry(default_type, token)
        if default_type == :ip
          [:ip, token]
        else
          norm = Llm::SpamUrls.normalize(token.sub(/\A\*\./, ''))
          return [nil, nil] unless norm

          if default_type == :url
            return [nil, nil] if norm[:path].blank?

            [:url, "#{norm[:host]}#{norm[:path]}"]
          else
            [:domain, norm[:host]]
          end
        end
      end

      # Протухание: активная запись не-local источника, чья выгрузка в этом
      # прогоне удалась, но который не видан в нём (seen_at старше прогона) —
      # soft-delete. Источник, чья выгрузка НЕ удалась, не трогаем: сбой
      # источника ≠ пустой список. Запись, которую в прошлом подтвердил
      # blocked-фид, сейчас упавший, тоже не трогаем: сбой ≠ исчезновение
      # ключа (fail-closed, раунд 14 — иначе сбой одного из пересекающихся
      # blocked-фидов стирал бы запись по факту владельца, выпустившего ключ
      # из своего списка). Успешный в прогоне источник защиты не даёт — у
      # него был шанс оставить ключ, и он им не воспользовался.
      # Записи source = local вне этой логики.
      def retire_stale(synced, run_at)
        synced.each do |entry_type, sources|
          scope = SpamBlockedEntry.unscoped
                                  .where(entry_type: entry_type, source: sources, deleted_at: nil)
                                  .where('seen_at < ? OR seen_at IS NULL', run_at)
          scope = exclude_failed_confirmed(scope, entry_type, sources)
          scope.in_batches(of: 10_000) { |rel| rel.update_all(deleted_at: run_at) }
        end
      end

      # Понижение «липкого» blocked (ревью Kimi, раунд 12): запись живёт
      # (seen_at свежий — suspect-источник её видит), владелец в этом прогоне
      # отсинковался успешно, но ключ не подтвердил ни один blocked-источник
      # (blocked_at старше прогона — у фидовых записей это метка последнего
      # подтверждения, см. flush_batch). Значит владелец ключ из состава
      # выпустил — понижаем до suspect, вечный blocked невозможен. Сбой
      # владельца его из synced убирает — понижения нет (fail-closed: сбой
      # источника ≠ исчезновение ключа, контракт runbook). Запись с
      # подтверждением от упавшего blocked-фида (раунд 14) тоже не понижаем.
      # local-записей тут нет по построению: в synced попадают только имена
      # фидов.
      def downgrade_unconfirmed_blocked(synced, run_at)
        synced.each do |entry_type, sources|
          scope = SpamBlockedEntry.unscoped
                                  .where(entry_type: entry_type, status: 'blocked', deleted_at: nil, source: sources)
                                  .where('seen_at >= ?', run_at)
                                  .where('blocked_at < ? OR blocked_at IS NULL', run_at)
          scope = exclude_failed_confirmed(scope, entry_type, sources)
          scope.in_batches(of: 10_000) { |rel| rel.update_all(status: 'suspect', blocked_at: nil, updated_at: run_at) }
        end
      end

      # Конфигурированные источники типа, не отсинковавшиеся в этом прогоне —
      # потенциальные «ранние подтверждатели» записей типа
      def failed_sources(entry_type, synced_sources)
        configured = entry_type.to_sym == :ip ? IP_FEEDS.keys : (DOMAIN_FEEDS.merge(URLHAUS_FEED)).keys
        configured - synced_sources
      end

      # Исключаем записи, у которых confirmations ссылаются на источники из
      # failed: такой источник ключ раньше подтверждал, а сейчас упал — сбой
      # ≠ исчезновение ключа (fail-closed, раунд 14)
      def exclude_failed_confirmed(scope, entry_type, synced_sources)
        failed = failed_sources(entry_type, synced_sources)
        return scope if failed.empty?

        placeholders = failed.map { '?' }.join(', ')
        scope.where.not("jsonb_exists_any(confirmations, ARRAY[#{placeholders}]::text[])", *failed)
      end

      def sync_allowlist
        zip_file = fetch(ALLOWLIST_URL)
        return 0 if zip_file.nil?

        csv = Zip.first_file(zip_file.read.to_s)
        return 0 if csv.blank?

        domains = csv.each_line.lazy.filter_map do |line|
          _rank, domain = line.strip.split(',', 2)
          domain&.strip&.downcase
        end.first(ALLOWLIST_TOP).to_a.uniq
        return 0 if domains.size < ALLOWLIST_MIN_ROWS

        now = Time.current
        SpamAllowlistEntry.transaction do
          # soft-delete не-manual записей; manual (ручные + наш домен) не трогаем
          SpamAllowlistEntry.unscoped.where(manual: false).update_all(deleted_at: now)
          existing = SpamAllowlistEntry.unscoped.where(domain: domains).pluck(:domain, :id, :manual).index_by(&:first)
          new_rows = []
          revive_ids = []
          domains.each do |domain|
            rec = existing[domain]
            if rec.nil?
              new_rows << { domain: domain, created_at: now, updated_at: now }
            elsif !rec[2] # не manual — реанимируем
              revive_ids << rec[1]
            end
          end
          new_rows.each_slice(1_000) do |slice|
            SpamAllowlistEntry.insert_all(slice, unique_by: :idx_spam_allowlist_entries_domain)
          end
          revive_ids.each_slice(10_000) do |ids|
            SpamAllowlistEntry.unscoped.where(id: ids).update_all(deleted_at: nil, updated_at: now)
          end
        end
        domains.size
      rescue StandardError => e
        Rails.logger.warn("[SpamFeeds] tranco_allowlist: синк не удался (#{e.class}: #{e.message})")
        0
      ensure
        zip_file&.close! if zip_file && !zip_file.closed?
      end

      # Потоковая загрузка во временный файл: тело ответа целиком в памяти
      # не держим, при превышении MAX_BODY_BYTES обрываем чтение (защита
      # ежедневного job от OOM). Редиректы проходим вручную (follow_redirects
      # в проекте нет): Tranco отдаёт 307 на /download/daily/…; URL в лог не
      # пишем — в нём может быть URLHAUS_EXPORT_URL с Auth-Key.
      def fetch(url, redirects: MAX_REDIRECTS)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 10
        http.read_timeout = 30

        total = 0
        tmp = Tempfile.new('spam_feed', binmode: true)
        http.start do |conn|
          conn.request(Net::HTTP::Get.new(uri)) do |res|
            if res.is_a?(Net::HTTPRedirection) && res['location'].present? && redirects.positive?
              tmp.close!
              return fetch(URI.join(url, res['location']).to_s, redirects: redirects - 1)
            end
            res.value # 4xx/5xx → Net::HTTPError без URL в тексте
            res.read_body do |chunk|
              total += chunk.bytesize
              if total > MAX_BODY_BYTES
                tmp.close!
                Rails.logger.warn("[SpamFeeds] ответ крупнее лимита #{MAX_BODY_BYTES} — отклонён")
                return nil
              end
              tmp.write(chunk)
            end
            # WebMock в спеках не отдаёт чанки через read_body-блок (подставляет
            # готовое тело) — пишем его напрямую, лимит тот же; у реального
            # ответа после read_body-блока body == nil, у WebMock-пустышки —
            # ReadAdapter без bytesize, оба случая пропускаем
            fallback = total.zero? ? res.body : nil
            if fallback.respond_to?(:bytesize) && fallback.bytesize.positive?
              if fallback.bytesize > MAX_BODY_BYTES
                tmp.close!
                Rails.logger.warn("[SpamFeeds] ответ крупнее лимита #{MAX_BODY_BYTES} — отклонён")
                return nil
              end
              tmp.write(fallback)
            end
          end
        end
        tmp.flush
        # Tempfile не отвечает на empty? — проверяем размер по пути
        if File.empty?(tmp.path)
          tmp.close!
          return nil
        end
        tmp.rewind
        tmp
      end
    end
  end
end
