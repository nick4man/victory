# frozen_string_literal: true

module Llm
  module SpamFeeds
    # Ежесуточный cron-синк антиспам-фидов (issue #219, задача в
    # config/sidekiq_cron.yml — spam_feeds_sync). Источники:
    #
    #   домены   — hagezi TIF/Fake, matomo referrer-spam, Phishing.Database,
    #              URLhaus (полные URL → записи url-уровня);
    #   IP       — stamparm/ipsum level 3, firehol cleantalk/stopforumspam/
    #              botscout 7d (включая CIDR-подсети);
    #   allowlist — Tranco Top-1M (официальный zip), верхние 10k — защита
    #              от самострела локальных эвристик.
    #
    # Пакетная загрузка (insert_all сотнями) — hagezi TIF это сотни тысяч
    # доменов, построчный find_or_create дал бы миллионы запросов. После
    # удачной выгрузки записи source, пропавшие из фида, протухают
    # (soft-delete): иначе выбывший из списков IP/домен блочился бы вечно.
    # Записи source = local синк не трогает.
    class SyncJob < ApplicationJob
      queue_as :low_priority

      # URL-фиды: строки — полные URL, пишем на url-уровне (host+path).
      URL_FEEDS = %w[phishing_links urlhaus].freeze
      DOMAIN_FEEDS = {
        'hagezi_tif'        => 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/tif.txt',
        'hagezi_fake'       => 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/fake.txt',
        'hagezi_shorteners' => 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/urlshortener.txt',
        'matomo_spammers'   => 'https://raw.githubusercontent.com/matomo-org/referrer-spam-list/master/spammers.txt',
        'phishing_domains'  => 'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-domains-ACTIVE.txt',
        'phishing_links'    => 'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-links-ACTIVE.txt',
        'urlhaus'           => 'https://urlhaus.abuse.ch/downloads/text/'
      }.freeze
      IP_FEEDS = {
        'ipsum_l3'              => 'https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt',
        'firehol_cleantalk'     => 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/cleantalk_7d.ipset',
        'firehol_stopforumspam' => 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/stopforumspam_7d.ipset',
        'firehol_botscout'      => 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/botscout_7d.ipset'
      }.freeze
      # Tranco Top-1M отдаётся только zip'ом; распаковка — Llm::SpamFeeds::Zip
      # (без rubyzip). Первые 10k строк — домены, которые локальные
      # эвристики не имеют права блочить на уровне корня.
      ALLOWLIST_URL = 'https://tranco-list.eu/top-1m.csv.zip'
      ALLOWLIST_TOP = 10_000
      # усечённая выгрузка не должна стирать рабочий allowlist целиком
      ALLOWLIST_MIN_ROWS = 9_000

      def perform
        stats = {}
        DOMAIN_FEEDS.each do |source, url|
          type = URL_FEEDS.include?(source) ? :url : :domain
          # шортенеры сами по себе не блок — только повод для эвристики
          status = source == 'hagezi_shorteners' ? :suspect : :blocked
          stats[source] = sync_list(url, source, type, status: status)
        end
        IP_FEEDS.each { |source, url| stats[source] = sync_list(url, source, :ip) }
        stats['tranco_allowlist'] = sync_allowlist
        Rails.logger.info("[SpamFeeds] синк завершён: #{stats.inspect}")
        stats
      end

      private

      # Одна выгрузка: нормализация → пакетный upsert → протухание. Фид,
      # вернувший пустой/битый ответ, НЕ стирает прежние записи — иначе
      # сбой источника обнулил бы защиту.
      def sync_list(url, source, default_type, status: :blocked)
        body = fetch(url)
        return 0 if body.blank?

        keys = []
        body.each_line do |line|
          token = line.split.first
          next if token.blank? || token.start_with?('#')

          type, key = normalize_entry(default_type, token)
          keys << [type, key] if key
        end
        keys.uniq!
        return 0 if keys.empty?

        upsert_batch(source, keys, status)
        retire_missing(source, keys)
        keys.size
      rescue StandardError => e
        Rails.logger.warn("[SpamFeeds] #{source}: синк не удался (#{e.class}: #{e.message})")
        0
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

      # insert_all новых + догон status'ом существующие (suspect → blocked,
      # когда фид довереннее). Конфликты по уникальному индексу пропускаются.
      def upsert_batch(source, keys, status)
        now = Time.current
        known = SpamBlockedEntry.where(source: source).pluck(:entry_type, :value, :id, :status)
                              .to_h { |type, value, id, st| [[type, value], [id, st]] }
        rows = []
        promote_ids = []
        keys.each do |type, key|
          if (rec = known[[type.to_s, key]])
            promote_ids << rec[0] if status == :blocked && rec[1] == 'suspect'
          else
            rows << { entry_type: type.to_s, value: key, source: source, status: status.to_s,
                      blocked_at: (now if status == :blocked), created_at: now, updated_at: now }
          end
        end
        rows.each_slice(1_000) do |slice|
          SpamBlockedEntry.insert_all(slice, unique_by: :idx_spam_blocked_entries_type_value)
        end
        promote_ids.each_slice(10_000) do |ids|
          SpamBlockedEntry.where(id: ids).update_all(status: 'blocked', blocked_at: now)
        end
      end

      # Записи источника, исчезнувшие из свежей выгрузки, протухают:
      # выбывший из публичных списков адрес не должен блочиться вечно.
      # local-записи сюда не попадают (source другой).
      def retire_missing(source, keys)
        fresh = keys.map(&:second).to_set
        stale_ids = SpamBlockedEntry.where(source: source).pluck(:id, :value)
                                    .filter_map { |id, value| id unless fresh.include?(value) }
        stale_ids.each_slice(10_000) do |ids|
          SpamBlockedEntry.where(id: ids).update_all(deleted_at: Time.current)
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
          # manual-записи (ручные исключения + наш домен) синк не стирает
          SpamAllowlistEntry.unscoped.where(manual: false).delete_all
          domains.each_slice(1_000) do |batch|
            SpamAllowlistEntry.insert_all(batch.map { |d| { domain: d, created_at: now, updated_at: now } })
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
