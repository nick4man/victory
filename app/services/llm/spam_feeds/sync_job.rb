# frozen_string_literal: true

module Llm
  module SpamFeeds
    # Ежесуточный cron-синк антиспам-фидов (issue #219, задача в
    # config/sidekiq_cron.yml — spam_feeds_sync). Источники:
    #
    #   домены   — hagezi TIF/Fake, matomo referrer-spam, Phishing.Database,
    #              URLhaus (полные URL → записи url-уровня);
    #   IP       — stamparm/ipsum level 3, firehol cleantalk/stopforumspam/
    #              botscout 7d;
    #   allowlist — снапшот Cisco Umbrella Top-1M (mozilla/cipherscan),
    #              верхние 10k — защита от самострела локальных эвристик.
    #
    # Идемпотентен: upsert по уникальному индексу (entry_type, value);
    # повторный прогон только догоняет расхождения. Падение одного фида
    # не роняет остальные — следующий прогон дозальёт.
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
      # Umbrella Top-1M как plain CSV (без зип-зависимостей). Первые 10k
      # строк — домены, которые локальные эвристики не имеют права блочить
      # на уровне корня.
      ALLOWLIST_URL = 'https://raw.githubusercontent.com/mozilla/cipherscan/master/top-1m.csv'
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
        stats['umbrella_allowlist'] = sync_allowlist
        Rails.logger.info("[SpamFeeds] синк завершён: #{stats.inspect}")
        stats
      end

      private

      def sync_list(url, source, default_type, status: :blocked)
        body = fetch(url)
        return 0 if body.blank?

        count = 0
        body.each_line do |line|
          token = line.split.first
          next if token.blank? || token.start_with?('#')

          type, key = normalize_entry(default_type, token)
          next if key.blank?

          upsert_entry(type, key, source, status: status)
          count += 1
        end
        count
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

      def upsert_entry(type, value, source, status:)
        entry = SpamBlockedEntry.find_or_create_by!(entry_type: type, value: value) do |e|
          e.source = source
          e.status = status
          e.blocked_at = Time.current if status == :blocked
        end
        # запись из фида довереннее локальной: suspect → blocked
        if status == :blocked && entry.status_suspect?
          entry.update_columns(status: 'blocked', blocked_at: Time.current)
        end
      rescue ActiveRecord::RecordNotUnique
        # гонка двух прогонов под одним индексом — повторный find догонит
        retry
      end

      def sync_allowlist
        body = fetch(ALLOWLIST_URL)
        domains = body.to_s.each_line.lazy.filter_map do |line|
          _rank, domain = line.strip.split(',', 2)
          domain&.strip&.downcase
        end.first(ALLOWLIST_TOP).to_a.uniq
        return 0 if domains.size < ALLOWLIST_MIN_ROWS

        now = Time.current
        SpamAllowlistEntry.transaction do
          SpamAllowlistEntry.unscoped.delete_all
          domains.each_slice(1_000) do |batch|
            SpamAllowlistEntry.insert_all(batch.map { |d| { domain: d, created_at: now, updated_at: now } })
          end
        end
        domains.size
      rescue StandardError => e
        Rails.logger.warn("[SpamFeeds] allowlist: синк не удался (#{e.class}: #{e.message})")
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
