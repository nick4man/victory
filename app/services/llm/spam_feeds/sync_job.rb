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
      # URLhaus с октября 2026 отдаёт keyless-экспорты 410 — нужен бесплатный
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
      # Tranco Top-1M отдаётся только zip'ом; распаковка — Llm::SpamFeeds::Zip
      # (без rubyzip). Первые 10k строк — домены, которые локальные
      # эвристики не имеют права блочить на уровне корня.
      ALLOWLIST_URL = 'https://tranco-list.eu/top-1m.csv.zip'
      ALLOWLIST_TOP = 10_000
      # усечённая выгрузка не должна стирать рабочий allowlist целиком
      ALLOWLIST_MIN_ROWS = 9_000

      def perform
        run_at = Time.current
        stats = {}
        # entry_type => источники, чья выгрузка в этом прогоне удалась
        synced = Hash.new { |h, k| h[k] = [] }

        (DOMAIN_FEEDS.merge(URLHAUS_FEED)).each do |source, cfg|
          imported = import_feed(source, cfg, run_at)
          stats[source] = imported
          synced[cfg[:entry_type] || :domain] << source if imported.positive?
        end
        IP_FEEDS.each do |source, cfg|
          imported = import_feed(source, cfg.merge(entry_type: :ip), run_at)
          stats[source] = imported
          synced[:ip] << source if imported.positive?
        end

        retire_stale(synced, run_at)
        stats['tranco_allowlist'] = sync_allowlist
        Rails.logger.info("[SpamFeeds] синк завершён: #{stats.inspect}")
        stats
      end

      private

      # Одна выгрузка: два прохода по телу (подсчёт для min_rows, затем
      # пакетная запись), чтобы в памяти жил только чанк BATCH строк.
      # Возвращает число записей фида; 0 — фид не синкнулся (нет URL, пустой,
      # битый, усечённый), тогда прежние записи источника не протухают.
      def import_feed(source, cfg, run_at)
        if cfg[:url].blank?
          Rails.logger.warn("[SpamFeeds] #{source}: URL не задан — фид пропущен")
          return 0
        end

        body = fetch(cfg[:url])
        return 0 if body.blank?

        entry_type = cfg[:entry_type] || :domain
        status = cfg[:status] || :blocked
        total = count_tokens(body, cfg)
        if total < cfg[:min_rows]
          Rails.logger.warn("[SpamFeeds] #{source}: подозрительно мало записей " \
                            "(#{total} < #{cfg[:min_rows]}) — выгрузка отклонена")
          return 0
        end

        import_batches(body, source, cfg, entry_type, status, run_at)
        total
      rescue StandardError => e
        Rails.logger.warn("[SpamFeeds] #{source}: синк не удался (#{e.class}: #{e.message})")
        0
      end

      def count_tokens(body, cfg)
        count = 0
        body.each_line do |line|
          token = parse_token(line, cfg[:format] || :plain)
          count += 1 if token.present?
        end
        count
      end

      # Пакетный upsert чанками. Уникальный индекс частичный (deleted_at IS
      # NULL): софт-делитная запись конфликта не даст, поэтому сначала
      # реанимируем вернувшиеся ключи, потом вставляем новые (on_conflict
      # skip), затем set-based помечаем seen_at и повышаем suspect → blocked
      # подтверждённым фидом (в т.ч. локальную запись).
      def import_batches(body, source, cfg, entry_type, status, run_at)
        batch = []
        flush = -> { flush_batch(batch, entry_type, status, run_at) }

        body.each_line do |line|
          token = parse_token(line, cfg[:format] || :plain)
          next if token.blank?

          type, key = cfg[:entry_type] == :ip ? [:ip, token] : normalize_entry(cfg.fetch(:entry_type, :domain), token)
          next unless key

          batch << { entry_type: type.to_s, value: key, source: source, status: status.to_s,
                     seen_at: run_at, blocked_at: (run_at if status == :blocked),
                     created_at: run_at, updated_at: run_at }
          flush.call if batch.size >= BATCH
        end
        flush.call
      end

      def flush_batch(batch, entry_type, status, run_at)
        return if batch.empty?

        values = batch.map { |r| r[:value] }
        scope = SpamBlockedEntry.unscoped.where(entry_type: entry_type, value: values)

        scope.where.not(deleted_at: nil)
             .update_all(deleted_at: nil, seen_at: run_at, updated_at: run_at)
        SpamBlockedEntry.insert_all(batch, unique_by: :idx_spam_blocked_entries_type_value)
        scope.update_all(seen_at: run_at, updated_at: run_at)
        if status == :blocked
          scope.where(status: 'suspect')
               .update_all(status: 'blocked', blocked_at: run_at, updated_at: run_at)
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

      # Доменные фиды приводим к единому виду фильтра; URL-фиды пишут
      # host+path. Ведущий '*.' (wildcard-записи Phishing.Database)
      # опускаем до доменного уровня.
      def normalize_entry(default_type, token)
        if default_type == :ip
          [:ip, token]
        else
          norm = Llm::SpamUrls.normalize(token.sub(/\A\*\./, ''))
          return [nil, nil] unless norm

          if default_type == :url && norm[:path].present?
            [:url, "#{norm[:host]}#{norm[:path]}"]
          else
            [:domain, norm[:host]]
          end
        end
      end

      # Протухание: активная запись не-local источника, чья выгрузка в этом
      # прогоне удалась, но который не видан в нём (seen_at старше прогона) —
      # soft-delete. Источник, чья выгрузка НЕ удалась, не трогаем: сбой
      # источника ≠ пустой список. Записи source = local вне этой логики.
      def retire_stale(synced, run_at)
        synced.each do |entry_type, sources|
          SpamBlockedEntry.unscoped
                          .where(entry_type: entry_type, source: sources, deleted_at: nil)
                          .where('seen_at < ? OR seen_at IS NULL', run_at)
                          .in_batches(of: 10_000) { |rel| rel.update_all(deleted_at: run_at) }
        end
      end

      def sync_allowlist
        csv = Zip.first_file(fetch(ALLOWLIST_URL))
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
      end

      def fetch(url)
        conn = Faraday.new do |f|
          f.options.open_timeout = 10
          f.options.read_timeout = 30
          f.response :raise_error
        end
        response = conn.get(url)
        body = response.body.to_s
        if body.bytesize > MAX_BODY_BYTES
          Rails.logger.warn("[SpamFeeds] #{url}: ответ #{body.bytesize} байт — больше лимита #{MAX_BODY_BYTES}, отклонён")
          return nil
        end
        body
      end
    end
  end
end
