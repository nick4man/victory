# frozen_string_literal: true

require 'net/http'
require 'nokogiri'
require 'uri'
require 'json'

module Nextcloud
  # Phase 7.8a — единая точка входа в Nextcloud (`cloud.victory62.org`).
  #
  # Использует WebDAV (`/remote.php/dav/files/<user>/`) для file ops + OCS Shares
  # API (`/ocs/v2.php/apps/files_sharing/api/v1/shares`) для public links.
  # ПУРЕ HTTP — rclone CLI не требуется (в web-контейнере не установлен).
  #
  # Credentials: `NEXTCLOUD_USER` + `NEXTCLOUD_PASS` из ENV. Host опционален
  # (default `cloud.victory62.org`).
  #
  # Safety guards:
  #   • `assert_safe_path!` — раздаёт Forbidden на sensitive-tier dirs:
  #     БУХГАЛТЕРИЯ, БЕЗОПАСНОСТЬ, ПРИХОДЬКО О.В. РАЗНОЕ, КРЕДИТЫ, Обмен.
  #   • Все write-ops (mkdir/upload/move) проходят через guard.
  #
  # @example list
  #   c = Nextcloud::Client.new
  #   c.exists?('Офис/НЕДВИЖИМОСТЬ')                   # => true
  #   c.list('Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ')      # => [{href:, type:, size:, modified:}, ...]
  #
  # @example upload + share
  #   c.mkdir_p('Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/123 ПРОДАЖА test Анна')
  #   c.upload('/tmp/dossier.pdf', 'Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/123 ПРОДАЖА test Анна/dossier.pdf')
  #   c.create_share(path: '...', password: 'XYZ', expire_date: Date.today + 7)
  #
  # @example sensitivity check
  #   c.exists?('Офис/БУХГАЛТЕРИЯ/2026')              # => raises Forbidden
  class Client
    class Error < StandardError; end
    class Forbidden < Error; end
    class NotFound < Error; end

    # Сегменты, которые НИКОГДА не трогаем (см. cheatsheet sensitivity matrix).
    SENSITIVE_SEGMENTS = ['БУХГАЛТЕРИЯ', 'БЕЗОПАСНОСТЬ', 'КРЕДИТЫ', 'Обмен'].freeze
    # Подстрока — ПРИХОДЬКО — это конкретный человек, любое его упоминание блокируется.
    SENSITIVE_SUBSTRINGS = ['ПРИХОДЬКО'].freeze

    DEFAULT_HOST = 'cloud.victory62.org'

    def initialize(user: ENV.fetch('NEXTCLOUD_USER'),
                   pass: ENV.fetch('NEXTCLOUD_PASS'),
                   host: ENV.fetch('NEXTCLOUD_HOST', DEFAULT_HOST))
      @user = user
      @pass = pass
      @host = host
    end

    # ------------------------------------------------------------------
    # WebDAV — file ops
    # ------------------------------------------------------------------

    def exists?(path)
      assert_safe_path!(path)
      res = webdav_request('PROPFIND', path, headers: { 'Depth' => '0' })
      res.is_a?(Net::HTTPMultiStatus) || res.is_a?(Net::HTTPOK)
    rescue NotFound
      false
    end

    # Listing one level deep (Depth=1). Возвращает Array<Hash>:
    #   { name:, type: :dir|:file, size: Integer, modified: Time }
    # Сам каталог (self-href) в результат не включается.
    def list(path)
      assert_safe_path!(path)
      res = webdav_request('PROPFIND', path, headers: { 'Depth' => '1' })
      raise NotFound, "WebDAV list #{path}: not found" if res.is_a?(Net::HTTPNotFound)

      parse_propfind_list(res.body, path)
    end

    # Создать одну директорию (parent должен существовать).
    # Phase 9 Iter 4: 405 (Method Not Allowed) и 409 (Conflict) трактуются как
    # «папка уже существует» (race с параллельным mkdir) — не ошибка.
    def mkdir(path)
      assert_safe_path!(path)
      res = webdav_request('MKCOL', path)
      return true if res.is_a?(Net::HTTPCreated)
      return true if %w[405 409].include?(res.code) # Concurrent mkdir won

      raise Error, "MKCOL #{path}: HTTP #{res.code}"
    end

    # Recursive mkdir — создаёт цепочку директорий (как mkdir -p).
    def mkdir_p(path)
      assert_safe_path!(path)
      parts = path.split('/').reject(&:empty?)
      parts.each_with_index do |_, i|
        sub = parts[0..i].join('/')
        next if exists?(sub)

        mkdir(sub)
      end
      true
    end

    def upload(local_path, remote_path)
      assert_safe_path!(remote_path)
      body = File.binread(local_path)
      res  = webdav_request('PUT', remote_path, body: body,
                                                headers: { 'Content-Type' => 'application/octet-stream' })
      raise Error, "PUT #{remote_path}: HTTP #{res.code}" unless res.is_a?(Net::HTTPCreated) || res.is_a?(Net::HTTPNoContent)

      true
    end

    def download(remote_path)
      assert_safe_path!(remote_path)
      res = webdav_request('GET', remote_path)
      raise NotFound, "GET #{remote_path}: 404" if res.is_a?(Net::HTTPNotFound)
      raise Error, "GET #{remote_path}: HTTP #{res.code}" unless res.is_a?(Net::HTTPOK)

      res.body
    end

    # ------------------------------------------------------------------
    # OCS Shares — public links (rclone link не работает)
    # ------------------------------------------------------------------

    # @param path [String] относительно DAV root (~/Files), е.g. "Офис/НЕДВИЖИМОСТЬ/<deal>/file.pdf"
    # @param password [String, nil] если nil — link открытый (не рекомендуется)
    # @param expire_date [Date, nil] последний день валидности
    # @param share_type [Integer] 3 = public link (по умолчанию)
    # @param permissions [Integer] 1 = read-only, 15 = read+write+share+delete
    # @return [Hash] { id:, url:, token:, password:, expiration: } или raises Error
    def create_share(path:, password: nil, expire_date: nil, share_type: 3, permissions: 1)
      assert_safe_path!(path)

      params = { path: "/#{path}", shareType: share_type, permissions: permissions }
      params[:password]   = password if password
      params[:expireDate] = expire_date.strftime('%Y-%m-%d') if expire_date

      res = ocs_request('POST', 'apps/files_sharing/api/v1/shares', body: params)
      data = parse_ocs(res)
      raise Error, "OCS create_share: #{ocs_message(res)}" unless data

      {
        id: data['id'],
        url: data['url'],
        token: data['token'],
        password: password,
        expiration: data['expiration']
      }
    end

    def delete_share(share_id)
      res = ocs_request('DELETE', "apps/files_sharing/api/v1/shares/#{share_id}")
      ocs_status_ok?(res)
    end

    # ------------------------------------------------------------------
    # Safety
    # ------------------------------------------------------------------

    def assert_safe_path!(path)
      segments = path.to_s.split('/').reject(&:empty?)
      sensitive_seg = (segments & SENSITIVE_SEGMENTS).first
      raise Forbidden, "Nextcloud sensitive segment: #{sensitive_seg} in #{path}" if sensitive_seg

      substr = SENSITIVE_SUBSTRINGS.find { |s| path.include?(s) }
      raise Forbidden, "Nextcloud sensitive substring: #{substr} in #{path}" if substr

      true
    end

    private

    # ---- Net::HTTP helpers ----

    # Кастомный HTTP-метод (PROPFIND/MKCOL) через Net::HTTPGenericRequest.
    def webdav_request(method, path, body: nil, headers: {})
      uri = webdav_uri(path)
      req = build_request(method, uri, body: body, headers: headers)
      req.basic_auth(@user, @pass)
      do_request(uri, req)
    end

    def ocs_request(method, path, body: nil)
      uri = URI("https://#{@host}/ocs/v2.php/#{path}?format=json")
      req = build_request(method, uri, body: body,
                                       headers: { 'OCS-APIRequest' => 'true',
                                                  'Content-Type' => 'application/x-www-form-urlencoded' })
      req.basic_auth(@user, @pass)
      do_request(uri, req)
    end

    def build_request(method, uri, body: nil, headers: {})
      klass = case method.to_s.upcase
              when 'GET'    then Net::HTTP::Get
              when 'PUT'    then Net::HTTP::Put
              when 'POST'   then Net::HTTP::Post
              when 'DELETE' then Net::HTTP::Delete
              when 'HEAD'   then Net::HTTP::Head
              else
                # PROPFIND, MKCOL — кастомные WebDAV методы. Net::HTTPGenericRequest
                # позволяет передать любую verb-строку.
                return Net::HTTPGenericRequest.new(method.to_s.upcase,
                                                   body ? true : false, true,
                                                   uri.request_uri, headers)
              end
      req = klass.new(uri.request_uri, headers)
      assign_body(req, body)
      req
    end

    def assign_body(req, body)
      return if body.nil?

      req.body = body.is_a?(Hash) ? URI.encode_www_form(body) : body
    end

    def do_request(uri, req)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                          open_timeout: 5, read_timeout: 60) { |h| h.request(req) }
    end

    def webdav_uri(path)
      URI("https://#{@host}/remote.php/dav/files/#{@user}/#{encode_path(path)}")
    end

    def encode_path(path)
      path.to_s.split('/').reject(&:empty?).map do |seg|
        URI.encode_www_form_component(seg).gsub('+', '%20')
      end.join('/')
    end

    # ---- PROPFIND parsing ----

    def parse_propfind_list(xml, parent_path)
      doc = Nokogiri::XML(xml)
      ns = { 'd' => 'DAV:' }
      results = []
      doc.xpath('//d:response', ns).each do |resp|
        href_el = resp.at_xpath('d:href', ns)
        next if href_el.nil?

        decoded_href = URI.decode_www_form_component(href_el.text.to_s.split('?', 2).first.to_s)
        # пропускаем сам каталог (self-link); запись на parent'а возвращается всегда
        next if self_link?(decoded_href, parent_path)

        results << build_propfind_entry(resp, decoded_href, ns)
      end
      results
    end

    def build_propfind_entry(resp, decoded_href, ns)
      prop  = resp.at_xpath('d:propstat/d:prop', ns)
      type  = prop&.at_xpath('d:resourcetype/d:collection', ns) ? :dir : :file
      size  = prop&.at_xpath('d:getcontentlength', ns)&.text.to_i
      mtime = prop&.at_xpath('d:getlastmodified', ns)&.text
      name  = decoded_href.split('/').reject(&:empty?).last
      { name: name, type: type, size: size, modified: mtime }
    end

    def self_link?(decoded_href, parent_path)
      cleaned = decoded_href.sub(%r{\A/remote\.php/dav/files/[^/]+/}, '').chomp('/')
      cleaned == parent_path.chomp('/')
    end

    # ---- OCS parsing ----

    def parse_ocs(res)
      return nil unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body || '{}')
      data.dig('ocs', 'data')
    rescue JSON::ParserError
      nil
    end

    def ocs_message(res)
      data = JSON.parse(res.body || '{}')
      data.dig('ocs', 'meta', 'message') || "HTTP #{res.code}"
    rescue JSON::ParserError
      "HTTP #{res.code}"
    end

    def ocs_status_ok?(res)
      return false unless res.is_a?(Net::HTTPSuccess)

      data = JSON.parse(res.body || '{}')
      data.dig('ocs', 'meta', 'status') == 'ok'
    rescue JSON::ParserError
      false
    end
  end
end
