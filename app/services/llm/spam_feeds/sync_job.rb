# frozen_string_literal: true

module Llm
  module SpamFeeds
    # Ежесуточный cron-синк антиспам-фидов (issue #219, задача в
    # config/sidekiq_cron.yml — spam_feeds_sync). Источники:
    #
    #   домены   — hagezi TIF/Fake (adblock-формат ||domain^), matomo
    #              referrer-spam, Phishing.Database (домены + полные URL);
    #   IP       — stamparm/ipsum level 3, firehol cleantalk/stopforumspam/
    #              botscout 7d (включая CIDR-подсети);
    #   allowlist — Tranco Top-1M (официальный zip), верхние 10k — защита
    #              от самострела локальных эвристик.
    #
    # Пакетная загрузка (insert_all сотнями) — hagezi TIF это сотни тысяч
    # доменов, построчный find_or_create дал бы миллионы запросов. После
    # удачной выгрузки записи, исчезнувшие из фидов, протухают (soft-delete):
    # иначе выбывший из списков IP/домен блочился бы вечно. Протухание
    # считается по объединению всех успешных фидов одного типа: поздний
    # источник не имеет права стирать ключ, который остался в свежем раннем
    # фиде. Записи source = local синк не трогает (кроме повышения статуса
    # suspect → blocked, когда домен подтверждён доверенным фидом).
    class SyncJob < ApplicationJob
      queue_as :low_priority

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
        'phishing_links'    => { url: 'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-links-ACTIVE.txt',
                                 format: :urls, min_rows: 1_000 }
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
        results = DOMAIN_FEEDS.filter_map do |source, cfg|
          fetch_list(cfg[:url], source, cfg)
        end
        results += IP_FEEDS.filter_map do |source, cfg|
          fetch_list(cfg[:url], source, cfg.merge(entry_type: :ip))
        end

        import_all(results) if results.any?

        stats = results.to_h { |r| [r[:source], r[:keys].size] }
        stats['tranco_allowlist'] = sync_allowlist
        Rails.logger.info("[SpamFeeds] синк завершён: #{stats.inspect}")
        stats
      end

      private

      # Одна выгрузка: парсинг по формату → нормализация. Возвращает nil
      # (фид считается несинкнувшимся), если ответ пуст, битый или резко
      # усечённый — тогда прежние записи этого источника не протухают.
      def fetch_list(url, source, cfg)
        body = fetch(url)
        return nil if body.blank?

        keys = []
        body.each_line do |line|
          token = parse_token(line, cfg[:format] || :plain)
          next if token.blank?

          type, key = cfg[:entry_type] == :ip ? [:ip, token] : normalize_entry(cfg.fetch(:entry_type, :domain), token)
          keys << [type, key] if key
        end
        keys.uniq!
        if keys.size < cfg[:min_rows]
          Rails.logger.warn("[SpamFeeds] #{source}: подозрительно мало записей " \
                            "(#{keys.size} < #{cfg[:min_rows]}) — выгрузка отклонена")
          return nil
        end
        { source: source, status: cfg[:status] || :blocked, keys: keys }
      rescue StandardError => e
        Rails.logger.warn("[SpamFeeds] #{source}: синк не удался (#{e.class}: #{e.message})")
        nil
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

      # Пакетный upsert по объединению всех успешных фидов. Статус записи —
      # сильнейший среди фидов с этим ключом (blocked > suspect): локальный
      # suspect, подтверждённый blocked-фидом, повышается; протухшие
      # (soft-deleted) ключи, вернувшиеся в фид, реанимируются.
      def import_all(results)
        best = {}   # [type, key] => :blocked | :suspect
        origin = {} # [type, key] => источник (для вновь создаваемых записей)
        results.each do |r|
          r[:keys].each do |type, key|
            k = [type, key]
            best[k] = :blocked if r[:status] == :blocked
            best[k] ||= r[:status]
            origin[k] ||= r[:source]
          end
        end

        types = best.keys.map(&:first).uniq
        known = SpamBlockedEntry.unscoped.where(entry_type: types)
                                 .index_by { |e| [e.entry_type.to_s, e.value] }

        now = Time.current
        new_rows = []
        promote_ids = []
        revive_blocked = []
        revive_suspect = []
        best.each do |(type, key), status|
          rec = known[[type.to_s, key]]
          if rec.nil?
            new_rows << { entry_type: type.to_s, value: key, source: origin[[type, key]],
                          status: status.to_s, blocked_at: (now if status == :blocked),
                          created_at: now, updated_at: now }
          elsif rec.deleted_at?
            (status == :blocked ? revive_blocked : revive_suspect) << rec.id
          elsif status == :blocked && rec.status != 'blocked'
            promote_ids << rec.id
          end
        end

        new_rows.each_slice(1_000) do |slice|
          SpamBlockedEntry.insert_all(slice, unique_by: :idx_spam_blocked_entries_type_value)
        end
        revive_blocked.each_slice(10_000) do |ids|
          SpamBlockedEntry.unscoped.where(id: ids)
                          .update_all(deleted_at: nil, status: 'blocked', blocked_at: now, updated_at: now)
        end
        revive_suspect.each_slice(10_000) do |ids|
          SpamBlockedEntry.unscoped.where(id: ids)
                          .update_all(deleted_at: nil, status: 'suspect', updated_at: now)
        end
        promote_ids.each_slice(10_000) do |ids|
          SpamBlockedEntry.where(id: ids).update_all(status: 'blocked', blocked_at: now, updated_at: now)
        end

        retire_stale(results, now)
      end

      # Протухание: активная запись не-local источника, чья выгрузка в этом
      # прогоне удалась, но чьего значения нет в объединении свежих фидов её
      # типа — soft-delete. Ключ, оставшийся хотя бы в одном успешном фиде,
      # не трогаем, даже если другой источник его уже не отдаёт.
      def retire_stale(results, now)
        sources_by_type = {}
        fresh_by_type = Hash.new { |h, k| h[k] = Set.new }
        results.each do |r|
          r[:keys].each do |type, key|
            (sources_by_type[type] ||= Set.new) << r[:source]
            fresh_by_type[type] << key
          end
        end

        sources_by_type.each do |type, sources|
          stale_ids = SpamBlockedEntry.unscoped
                                      .where(entry_type: type, deleted_at: nil, source: sources.to_a)
                                      .pluck(:id, :value)
                                      .filter_map { |id, value| id unless fresh_by_type[type].include?(value) }
          stale_ids.each_slice(10_000) do |ids|
            SpamBlockedEntry.unscoped.where(id: ids).update_all(deleted_at: now)
          end
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
        conn.get(url).body
      end
    end
  end
end
