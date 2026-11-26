# frozen_string_literal: true

module Chat
  # Тест-контур чат-виджета — довоз фич из закрытого PR #230 (issue #249).
  #
  # Сигналы, в порядке приоритета:
  #   1. probe-cookie (#228/#229) — визит активирован секретной ссылкой
  #      (?visitor_token=probe-<имя>&probe_key=<секрет>);
  #   2. кран ENV SITE_CHATBOT_FORCE_TEST — весь сайт-чат принудительно
  #      тестовый (стенды/демо), в проде по умолчанию выключен;
  #   3. доверенный Origin/Referer — стенды *.dev.victory62.org и localhost;
  #   4. внутренние подсети RFC1918 (loopback исключён — см. ниже).
  #
  # Все сигналы сводятся к одному маркеру — metadata['test_probe']
  # Conversation — и дальше работают СУЩЕСТВУЮЩИЕ гейты #228: LlmReplyJob
  # ставит lead_test_mode, лиды/оценки получают metadata['test']=true,
  # эскалация уходит в тестовый TG-чат, KPI/dashboard фильтруют staff_test.
  #
  # Origin/Referer контролирует посетитель: «притвориться тестовым» может
  # только сам посетитель, и это лишь изолирует ЕГО собственный диалог
  # (fail-safe направление) — контур привязан к visitor_token cookie, чужие
  # сессии недостижимы. Боевой домен victory62.org в доверенные списки не
  # входит и попасть туда не может: иначе весь прод стал бы тестовым.
  #
  # Loopback исключён из подсетей намеренно: request-спеки и healthcheck
  # ходят с 127.0.0.1, а локальная разработка и так закрывается
  # origin-сигналом (браузер шлёт Origin/Referer http://localhost:PORT).
  class TestMode
    PROBE_COOKIE   = 'probe_cookie'
    FORCE_ENV      = 'force_env'
    TRUSTED_ORIGIN = 'trusted_origin'
    TRUSTED_IP     = 'trusted_ip'

    # Стендовый wildcard-домен Traefik (сертификат *.dev.victory62.org,
    # см. config/environments/staging.rb).
    STAGING_DOMAIN_SUFFIX = '.dev.victory62.org'
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
    # RFC1918 без loopback (см. комментарий класса).
    DEFAULT_TRUSTED_CIDRS = %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16].freeze

    Result = Struct.new(:test, :reason, keyword_init: true) do
      def test?
        test == true
      end
    end

    def initialize(request:, probe_cookie: false)
      @request = request
      @probe_cookie = probe_cookie
    end

    def call
      return Result.new(test: true, reason: PROBE_COOKIE) if @probe_cookie
      return Result.new(test: true, reason: FORCE_ENV) if self.class.force_test?
      return Result.new(test: true, reason: TRUSTED_ORIGIN) if trusted_origin?
      return Result.new(test: true, reason: TRUSTED_IP) if trusted_ip?

      Result.new(test: false, reason: nil)
    end

    class << self
      # Кран «весь сайт-чат в тестовый контур»: включается только ENV, прод
      # по умолчанию боевой. Читаем на каждый вызов — стенд может включить
      # контур правкой .env без пересборки образа. Значения по образцу
      # bin/rollout: 1/true/yes/on.
      def force_test?
        %w[1 true yes on].include?(ENV['SITE_CHATBOT_FORCE_TEST'].to_s.strip.downcase)
      end

      # Дополнительные доверенные hosts поверх встроенных (ENV, через
      # запятую), например «stg.example.com».
      def extra_trusted_hosts
        ENV['CHAT_TEST_TRUSTED_ORIGINS'].to_s.split(',').map { |h| h.strip.downcase }.reject(&:empty?)
      end

      # Внутренние подсети: встроенные RFC1918 + дополнительные из ENV
      # (CIDR или одиночные адреса). Битые записи молча пропускаем —
      # кривой ENV не должен ронять чат.
      def trusted_ip_addrs
        cidrs = DEFAULT_TRUSTED_CIDRS +
                ENV['CHAT_TEST_TRUSTED_IPS'].to_s.split(',').map(&:strip).reject(&:empty?)
        cidrs.filter_map do |c|
          IPAddr.new(c)
        rescue IPAddr::InvalidAddressError
          nil
        end
      end
    end

    private

    # Origin авторитетен, если задан (браузер шлёт его с каждым POST): на
    # Referer fallback'аем только при его отсутствии, иначе пара «чужой
    # Origin + доверенный Referer» обходила бы сигнал.
    def trusted_origin?
      host = host_of(@request.headers['Origin'].to_s)
      host = host_of(@request.headers['Referer'].to_s) if host.empty?
      trusted_host?(host)
    end

    def trusted_host?(host)
      LOCAL_HOSTS.include?(host) ||
        host.end_with?(STAGING_DOMAIN_SUFFIX) ||
        self.class.extra_trusted_hosts.include?(host)
    end

    def host_of(raw_url)
      URI.parse(raw_url).host.to_s.downcase.gsub(%r{\A\[|\]\z}, '')
    rescue URI::InvalidURIError
      ''
    end

    def trusted_ip?
      remote = @request.remote_ip.to_s
      return false if remote.empty?

      begin
        addr = IPAddr.new(remote)
      rescue IPAddr::InvalidAddressError
        return false
      end
      self.class.trusted_ip_addrs.any? { |cidr| cidr.include?(addr) }
    end
  end
end
