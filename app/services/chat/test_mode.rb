# frozen_string_literal: true

require 'ipaddr'

module Chat
  # Политика тест-изоляции лидов чат-бота сайта (issue #227). Три механизма,
  # по убыванию надёжности:
  #
  #   1. ENV-кран SITE_CHATBOT_FORCE_TEST=1 — ВСЕ site-лиды тестовые,
  #      ДИСПЕТЧЕРСКАЯ не трогается вовсе. Ставится на прогоны, снимается
  #      перед боевым периодом. Единственная 100%-я гарантия.
  #   2. Auto-test по происхождению — сессия с не-прод хоста (staging,
  #      localhost), с IP из офисного пула или с дев/стейджинг Origin/Referer
  #      автоматически тестовая.
  #   3. Тумблер «🧪 Тест-прогон» / probe-токен — явный выбор в UI виджета.
  #
  # Честное ограничение: прогон «как реальный клиент» с чужими контактами
  # с прод-домена без крана/тумблера неотличим от боевого лида — любая
  # эвристика рискует заблокировать реального клиента (неприемлемо).
  module TestMode
    # Источники Lead::Intake, которые порождают лиды чат-бота/сайта.
    # Кран (п.1) действует только на записи чат-бота среди них: tg_dm /
    # manual / crm_webhook чат-ботом сайта не являются и боевым маршрутом
    # не трогаются.
    SITE_SOURCES = %w[site_form site_valuation site_mortgage].freeze

    DEFAULT_PROD_HOSTS = 'victory62.org,www.victory62.org'

    def self.force_test?
      ENV['SITE_CHATBOT_FORCE_TEST'] == '1'
    end

    def self.site_source?(source)
      SITE_SOURCES.include?(source.to_s)
    end

    # Кран — строго про лиды чат-бота (rev #230): у записи чат-бота при
    # создании лида всегда есть Inquiry source='site_chatbot' (её делает
    # QualifyLead), поэтому кран не задевает обычные боевые формы сайта
    # (ContactFormsController/PropertyValuationsController идут теми же
    # site_* источниками). Без этого реальные заявки клиентов уехали бы в
    # тестовый чат на время прогона.
    def self.force_test_inquiry?(inquiry)
      inquiry.is_a?(Inquiry) && inquiry.source == 'site_chatbot'
    end

    # П.2 issue #227: сессия, начатая не с прод-домена или с офисного IP,
    # автоматически тестовая — ловит забывших тумблер на staging. Origin и
    # Referer тоже учитываем (rev #230): виджет со staging/localhost может
    # стучаться на боевой endpoint напрямую — по Host такой запрос
    # неотличим, по заголовкам происхождения отличим.
    def self.auto_test_request?(request)
      return true if office_ip?(request.remote_ip)
      return true unless prod_host?(request.host)

      non_prod_origin?(request)
    end

    def self.non_prod_origin?(request)
      [request.headers['Origin'], request.headers['Referer']].any? do |value|
        dev_origin?(host_from_url(value))
      end
    end

    # Auto-test по Origin/Referer (rev #230): помечаем только дев/стейджинг
    # источники — localhost, приватные IP, поддомены боевых доменов
    # (staging.victory62.org) и служебные TLD. Внешний Referer (поисковики,
    # агрегаторы) НЕ делает сессию тестовой: реальный клиент, пришедший по
    # рекламе, боевым остаётся.
    def self.dev_origin?(host)
      return false if host.blank?

      h = host.downcase
      return true if %w[localhost 127.0.0.1 ::1 0.0.0.0].include?(h)
      return true if h.end_with?('.local', '.test', '.internal', '.lan')
      return true if private_ip?(h)

      # Поддомен боевого домена (staging.victory62.org), но не сам прод-хост
      # и не его www-алиас — они в prod_hosts.
      !prod_hosts.include?(h) && prod_hosts.any? { |prod| h.ends_with?(".#{prod}") }
    end

    def self.private_ip?(host)
      IPAddr.new(host).private?
    rescue IPAddr::InvalidAddressError
      false
    end

    def self.host_from_url(value)
      return nil if value.blank?

      URI.parse(value.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    def self.prod_host?(host)
      prod_hosts.include?(host.to_s.downcase.split(':').first)
    end

    # Переопределяется через ENV (SITE_CHATBOT_PROD_HOSTS, comma-separated) для
    # прогонов через нестандартный боевой домен. ВНИМАНИЕ: не добавлять сюда
    # стейджинг/localhost — хост из списка auto-test НЕ получает (механизм 4
    # работает только для хостов вне этого списка).
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
