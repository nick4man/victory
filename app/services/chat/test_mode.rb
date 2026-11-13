# frozen_string_literal: true

module Chat
  # Политика тест-изоляции лидов чат-бота сайта (issue #227). Три механизма,
  # по убыванию надёжности:
  #
  #   1. ENV-кран SITE_CHATBOT_FORCE_TEST=1 — ВСЕ site-лиды тестовые,
  #      ДИСПЕТЧЕРСКАЯ не трогается вовсе. Ставится на прогоны, снимается
  #      перед боевым периодом. Единственная 100%-я гарантия.
  #   2. Auto-test по происхождению — сессия с не-прод хоста (staging,
  #      localhost) или с IP из офисного пула автоматически тестовая.
  #   3. Тумблер «🧪 Тест-прогон» / probe-токен — явный выбор в UI виджета.
  #
  # Честное ограничение: прогон «как реальный клиент» с чужими контактами
  # с прод-домена без крана/тумблера неотличим от боевого лида — любая
  # эвристика рискует заблокировать реального клиента (неприемлемо).
  module TestMode
    # Источники Lead::Intake, которые порождают лиды чат-бота/сайта.
    # Кран (п.1) действует только на них: tg_dm / manual / crm_webhook
    # чат-ботом сайта не являются и боевым маршрутом не трогаются.
    SITE_SOURCES = %w[site_form site_valuation site_mortgage].freeze

    DEFAULT_PROD_HOSTS = 'victory62.org,www.victory62.org'

    def self.force_test?
      ENV['SITE_CHATBOT_FORCE_TEST'] == '1'
    end

    def self.site_source?(source)
      SITE_SOURCES.include?(source.to_s)
    end

    # П.2 issue #227: сессия, начатая не с прод-домена или с офисного IP,
    # автоматически тестовая — ловит забывших тумблер на staging.
    def self.auto_test_request?(request)
      !prod_host?(request.host) || office_ip?(request.remote_ip)
    end

    def self.prod_host?(host)
      prod_hosts.include?(host.to_s.downcase.split(':').first)
    end

    # Переопределяется через ENV для стейджинга-прогонов с отдельного домена
    # (добавить его сюда временно), по умолчанию — прод-домены АН.
    def self.prod_hosts
      (ENV['SITE_CHATBOT_PROD_HOSTS'].presence || DEFAULT_PROD_HOSTS)
        .split(',')
        .map { |h| h.strip.downcase }
    end

    def self.office_ip?(ip)
      return false if ip.blank?

      office_ips.any? do |net|
        ip.to_s == net || ip.to_s.start_with?(net.end_with?('.') ? net : "#{net}.")
      end
    end

    # Офисный пул — comma-separated, точный IP или префикс подсети
    # ('192.168.1.' матчит 192.168.1.x, '10.0.0.5' — только сам адрес).
    def self.office_ips
      (ENV['SITE_CHATBOT_OFFICE_IPS'].presence || '')
        .split(',')
        .map(&:strip)
        .reject(&:empty?)
    end
  end
end
