# frozen_string_literal: true

module Sandbox
  # Песочница карточек CRM живёт в GitHub Codespace и засыпает после простоя.
  # Отсюда её будит команда /starttest: разработчику не нужно быть у ноутбука,
  # чтобы проверяющий начал тестировать.
  #
  # Токен — отдельный PAT со scope `codespace` в GITHUB_CODESPACE_TOKEN. Прав
  # на репозиторий ему не нужно: старт и статус живут в /user/codespaces.
  class Codespace
    API = 'https://api.github.com'
    DISPLAY_NAME = ENV.fetch('SANDBOX_CODESPACE_NAME', 'crm-sandbox')
    READY_STATES = %w[Available Provisioning Starting Queued].freeze

    class Error < StandardError; end

    Status = Struct.new(:name, :state, :branch, :web_url, :last_used_at, keyword_init: true) do
      def awake? = state == 'Available'
      def starting? = %w[Provisioning Starting Queued Rebuilding].include?(state)
    end

    def self.start! = new.start!
    def self.status = new.status

    # @return [Status]
    # @raise [Error] нет токена, нет такого codespace или GitHub ответил ошибкой
    def status
      find!
    end

    # Идемпотентно: разбуженный codespace остаётся разбуженным.
    # @return [Status]
    def start!
      current = find!
      return current if current.awake?

      post("/user/codespaces/#{current.name}/start")
      find!
    end

    private

    def token
      value = ENV.fetch('GITHUB_CODESPACE_TOKEN', nil)
      raise Error, 'GITHUB_CODESPACE_TOKEN не задан — песочницу будить нечем.' if value.blank?

      value
    end

    def find!
      list = get('/user/codespaces').fetch('codespaces', [])
      # display_name задаёт человек при создании, name генерируется GitHub.
      found = list.find { |cs| cs['display_name'] == DISPLAY_NAME || cs['name'] == DISPLAY_NAME }
      raise Error, "Codespace «#{DISPLAY_NAME}» не найден — создай его или поправь SANDBOX_CODESPACE_NAME." unless found

      Status.new(name: found['name'], state: found['state'], branch: found.dig('git_status', 'ref'),
                 web_url: found['web_url'], last_used_at: found['last_used_at'])
    end

    def get(path) = request(Net::HTTP::Get.new(URI("#{API}#{path}")))
    def post(path) = request(Net::HTTP::Post.new(URI("#{API}#{path}")))

    def request(req)
      req['Authorization'] = "Bearer #{token}"
      req['Accept'] = 'application/vnd.github+json'
      req['X-GitHub-Api-Version'] = '2022-11-28'
      res = Net::HTTP.start(req.uri.host, req.uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20) do |http|
        http.request(req)
      end
      raise Error, "GitHub ответил #{res.code} на #{req.method} #{req.uri.path}" unless res.is_a?(Net::HTTPSuccess)

      res.body.present? ? JSON.parse(res.body) : {}
    rescue JSON::ParserError, SocketError, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED => e
      raise Error, "GitHub недоступен: #{e.class}"
    end
  end
end
