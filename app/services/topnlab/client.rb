# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

# HTTP client for the Topnlab CRM public API.
# Documentation: /home/q/document_pdf.md
#
# Authentication: API key passed as `key=` query param (or `appkey` in JSON body
# for getUsers/getStructure). Rate limits: 1 req/6s for /get-ids and /get-entities,
# 1 req/1s for /get-entities-from-mls, /get-entities-from-parser, /get-entities-logs.
module Topnlab
  class Client
    class Error < StandardError; end

    SLOW_DELAY = 6.0   # /get-ids, /get-entities
    FAST_DELAY = 1.0   # /mls, /parser, /logs

    def initialize(api_key: ENV.fetch('TOPNLAB_API_KEY', nil), base_url: ENV.fetch('TOPNLAB_BASE_URL', nil))
      raise Error, 'TOPNLAB_API_KEY missing' if api_key.blank?
      raise Error, 'TOPNLAB_BASE_URL missing' if base_url.blank?

      @api_key = api_key
      @base_url = base_url.chomp('/')
      @last_request_at = {}
    end

    # GET /public/get-ids
    # @return [Array<Integer>]  bare array of ids; пусто = []
    # @raise [Topnlab::Client::Error] если ответ — НЕ массив.
    #
    # Не-массивный 200 (`{"status":"error"}`, `{}`, `null`) или 404→nil трактуем как
    # ошибку fetch, а НЕ как пустую выгрузку: молчаливый `[]` неотличим от легитимно
    # пустого результата, и на нём Importer#archive_missing обнулил бы весь каталог
    # (prod-инцидент). Raise отправляет такой сегмент через fetch_errors-guard (PR #6),
    # где archive пропускается. Легитимный `[]` остаётся валидным и не бросает.
    def get_ids(type:, action: nil, realty_type: nil, is_feed: nil, **filters)
      params = filters.merge(key: @api_key, type: type)
      params[:action] = action if action
      params[:realty_type] = realty_type if realty_type
      params[:is_feed] = is_feed unless is_feed.nil?

      data = http_get('/get-ids', params, throttle: :slow)
      unless data.is_a?(Array)
        raise Error,
              "get-ids вернул не-массив (#{data.class}) — трактуем как fetch failure, " \
              "не как пустую выгрузку (защита каталога от ложного archive): " \
              "#{data.inspect.truncate(200)}"
      end

      data
    end

    # GET /public/get-entities — batches up to 300 ids
    # @return [Hash{String => Hash}]  { "123" => { id:, ... } }
    def get_entities(ids, type: 'realty', append: nil)
      ids = Array(ids).compact.uniq
      return {} if ids.empty?

      result = {}
      ids.each_slice(300) do |chunk|
        params = { key: @api_key, type: type }
        chunk.each_with_index { |id, i| params["id[#{i}]"] = id }
        params[:append] = append if append
        data = http_get('/get-entities', params, throttle: :slow)
        result.merge!(data) if data.is_a?(Hash)
      end
      result
    end

    # GET /public/get-entities-from-mls — batches up to 100
    def get_entities_from_mls(ids)
      batched_get('/get-entities-from-mls', ids, batch_size: 100, throttle: :fast)
    end

    # GET /public/get-entities-from-parser — batches up to 100
    def get_entities_from_parser(ids)
      batched_get('/get-entities-from-parser', ids, batch_size: 100, throttle: :fast)
    end

    # GET /public/realty/getoptions
    def get_realty_options
      http_get('/realty/getoptions', { key: @api_key }, throttle: :fast)
    end

    # POST /public/getUsers/  (JSON body { appkey: ... })
    # Topnlab returns one of:
    #   { "status": "ok", "data": { "id" => { firstname:, ... } } }   (per docs)
    #   { "status": "ok", "data": { "data": [ {...}, {...} ] } }      (observed in practice)
    # We normalise to a flat array of user hashes.
    # @return [Array<Hash>]
    def get_users
      body = http_post_json('/getUsers/', appkey: @api_key)
      data = body.is_a?(Hash) ? body['data'] : nil
      case data
      when Array then data
      when Hash
        if data['data'].is_a?(Array)
          data['data']
        else
          data.values.flatten
        end
      else
        []
      end
    end

    # POST /public/getStructure/
    def get_structure
      http_post_json('/getStructure/', appkey: @api_key)
    end

    # GET /public/stages?<scope_id>=...
    # scope_id: -1 (Покупатели), -2 (Арендаторы), -3 (Продавцы), -4 (Арендодатели), or service-type id.
    def get_stages(scope_id)
      http_get('/stages', { key: @api_key, scope_id => '' }, throttle: :fast)
    end

    # GET /public/get-notes — public notes attached to one entity.
    def get_notes(id:, type:)
      http_get('/get-notes', { key: @api_key, id: id, type: type }, throttle: :fast)
    end

    # POST /public/set-note — push a public note to an entity.
    def set_note(id:, type:, note:, user_id:)
      http_post_json('/set-note', key: @api_key, id: id, type: type, note: note, user_id: user_id)
    end

    # GET /public/get-entities-logs — change history; up to 100 ids per request, fast throttle.
    def get_entities_logs(ids, event_type: nil, created_from: nil, created_till: nil)
      ids = Array(ids).compact.uniq
      return [] if ids.empty?

      result = []
      ids.each_slice(100) do |chunk|
        params = { key: @api_key }
        chunk.each_with_index { |id, i| params["id[#{i}]"] = id }
        params[:event_type]   = event_type   if event_type
        params[:created_from] = created_from if created_from
        params[:created_till] = created_till if created_till
        data = http_get('/get-entities-logs', params, throttle: :fast)
        result.concat(Array(data)) if data
      end
      result
    end

    # POST /public/get-event-types — справочник event_type кодов для logs.
    def get_event_types
      http_get('/get-event-types', { key: @api_key }, throttle: :fast)
    end

    # POST /public/menu/list/  — list registered custom report menu items.
    def list_report_menus
      http_post_json('/menu/list/', appkey: @api_key)
    end

    # GET /public/menu/get-all-pages — page_id справочник для отчётов.
    def report_pages
      http_get('/menu/get-all-pages', { key: @api_key }, throttle: :fast)
    end

    # GET /public/menu/create — register a new custom report.
    def create_report_menu(title:, page_id:, order:, callback_url:)
      http_get('/menu/create',
               { key: @api_key, title: title, page_id: page_id, order: order, url: callback_url },
               throttle: :fast)
    end

    # GET /public/menu/update — rename / reorder existing report.
    def update_report_menu(id:, title:, order:)
      http_get('/menu/update',
               { key: @api_key, id: id, title: title, order: order },
               throttle: :fast)
    end

    # GET /public/menu/delete — drop a report.
    def delete_report_menu(id:)
      http_get('/menu/delete', { key: @api_key, id: id }, throttle: :fast)
    end

    # POST /public/clients/get-by-entity — fetch физлица (clients) linked to an entity.
    # entity_type: 2=realty, 3=order, 4=service.
    # Returns array of client hashes: id, firstname, lastname, fathername, phones[], emails[].
    # Used to populate Property#owner_user_id (seller client linkage).
    #
    # @param entity_id [Integer] Topnlab card id
    # @param entity_type [Integer] 2=объект, 3=заявка, 4=услуга
    # @return [Array<Hash>] list of client records; empty array on error/not-found
    def get_clients_by_entity(entity_id:, entity_type: 2)
      body = { key: @api_key, entity_id: entity_id.to_i, entity_type: entity_type.to_i }
      response = http_post_json('/clients/get-by-entity', body)
      return [] unless response.is_a?(Hash) && %w[ok success].include?(response['status'])

      clients = response.dig('data', 'clients')
      Array(clients).compact
    rescue Topnlab::Client::Error => e
      Rails.logger.warn("[Topnlab] get_clients_by_entity entity_id=#{entity_id}: #{e.message}")
      []
    end

    # POST /public/get-entities  with patch[] body — update fc_* custom fields on an entity.
    def patch_entity(id:, type:, fields:)
      http_post_json('/get-entities',
                     id: id, key: @api_key, type: type,
                     patch: [{ id: id, data: fields }])
    end

    # POST /call/main/importClient/ — создать лид в Topnlab CRM.
    # Используется Lead::Intake::* источниками для проброса заявок с сайта/TG в CRM.
    #
    # @param phone [String] любой формат — нормализуется в 11 цифр (7XXXXXXXXXX)
    # @param name [String] ФИО / имя клиента (обязательно)
    # @param source [String] Lead::Intake источник (site_form|site_valuation|site_mortgage|tg_dm|manual)
    # @param realty_id [Integer, nil] Topnlab short_id объекта если лид по конкретному
    # @param comment [String, nil] до 500 символов
    # @param action [Integer, nil] 0=аренда, 1=продажа (если nil — выводится из source)
    # @param object_type [String] flat|room|commerce|house|land|garage
    # @param to_number [String, nil] входящий номер (если лид пришёл по звонку)
    # @return [Hash] {"status" => "ok", "insertedId" => <order_id>}
    # @raise [Topnlab::Client::Error] на любую неуспешную попытку
    def import_client(phone:, name:, source:, realty_id: nil, comment: nil,
                      action: nil, object_type: 'flat', to_number: nil)
      body = {
        appkey: @api_key,
        fullname: name.to_s.strip,
        phone: normalize_phone_11d(phone),
        action: action || source_to_action(source),
        object_type: object_type
      }
      body[:comment]                    = comment.to_s[0, 500]                  if comment.present?
      body[:called_for_object_short_id] = realty_id.to_i                        if realty_id
      body[:to_number]                  = to_number if to_number.present?

      res = http_post_json('/call/main/importClient/', body)
      unless res.is_a?(Hash) && res['status'] == 'ok'
        raise Error, "importClient failed: #{res.inspect}"
      end

      res
    end

    # POST /call/main/transferClient/ — назначить лид агенту в Topnlab по email.
    # Опционально меняет stage_id (стадия воронки).
    #
    # @param order_id [Integer] CRM id заявки (insertedId из import_client / BuyerOrder.crm_id)
    # @param email [String] email агента в Topnlab (соответствует TelegramUser#email)
    # @param stage_id [Integer, nil] числовой id стадии (см. get_stages(-1) для покупателей)
    # @return [Hash] {"status" => "ok"}
    # @raise [Topnlab::Client::Error] на любую неуспешную попытку
    def transfer_client(order_id:, email:, stage_id: nil)
      body = { appkey: @api_key, client_id: order_id.to_i, user_mail: email.to_s.strip }
      body[:stage_id] = stage_id.to_i if stage_id

      res = http_post_json('/call/main/transferClient/', body)
      unless res.is_a?(Hash) && res['status'] == 'ok'
        raise Error, "transferClient failed: #{res.inspect}"
      end

      res
    end

    private

    # Topnlab требует ровно 11 цифр без +/пробелов/скобок (формат 7XXXXXXXXXX).
    # Превращает '+7 (900) 123-45-67' → '79001234567', '89001234567' → '79001234567'.
    def normalize_phone_11d(phone)
      digits = phone.to_s.gsub(/\D/, '')
      digits = "7#{digits[1..]}" if digits.start_with?('8') && digits.length == 11
      unless digits.length == 11
        raise Error,
              "invalid phone (#{phone.inspect}) — expected 11 digits, got #{digits.length}"
      end

      digits
    end

    # Маппинг Lead::Intake источника → Topnlab action.
    # 0 = аренда, 1 = продажа. В Фазе 2 все источники — продажа.
    # Phase 4 (TG-DM с rent-намерением) добавит явный branch.
    def source_to_action(_source)
      1
    end

    def batched_get(path, ids, batch_size:, throttle:)
      ids = Array(ids).compact.uniq
      result = {}
      ids.each_slice(batch_size) do |chunk|
        params = { key: @api_key }
        chunk.each_with_index { |id, i| params["id[#{i}]"] = id }
        data = http_get(path, params, throttle: throttle)
        result.merge!(data) if data.is_a?(Hash)
      end
      result
    end

    def http_get(path, params, throttle:)
      throttle!(throttle)
      uri = URI("#{@base_url}#{path}")
      uri.query = encode_query(params)
      response = perform(Net::HTTP::Get.new(uri))
      parse(response, "GET #{path}")
    end

    def http_post_json(path, body)
      throttle!(:fast)
      uri = URI("#{@base_url}#{path}")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req.body = body.to_json
      response = perform(req)
      parse(response, "POST #{path}")
    end

    def perform(request)
      http = Net::HTTP.new(request.uri.host, request.uri.port)
      http.use_ssl = (request.uri.scheme == 'https')
      http.read_timeout = 60
      http.open_timeout = 30
      attempts = 0
      begin
        http.request(request)
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::EPIPE => e
        attempts += 1
        if attempts <= 2
          sleep(2 * attempts)
          retry
        end
        raise Error, "Topnlab network failure after #{attempts} retries: #{e.class}: #{e.message}"
      end
    end

    # Topnlab requires PHP-style `key[]=v1&key[]=v2` for array filters
    # (e.g. deal_state). URI.encode_www_form would emit `key=v1&key=v2`
    # which Topnlab interprets as the LAST value only. Expand arrays manually.
    def encode_query(params)
      pairs = params.flat_map do |key, value|
        if value.is_a?(Array)
          value.map { |v| ["#{key}[]", v] }
        else
          [[key.to_s, value]]
        end
      end
      URI.encode_www_form(pairs)
    end

    def parse(response, label)
      body = response.body.to_s
      case response.code.to_i
      when 200, 201
        JSON.parse(body)
      when 403
        raise Error, "#{label}: 403 Forbidden — API key rejected"
      when 404
        Rails.logger.warn("Topnlab #{label}: 404 not found")
        nil
      else
        raise Error, "#{label}: HTTP #{response.code} — #{body.truncate(500)}"
      end
    rescue JSON::ParserError => e
      raise Error, "#{label}: invalid JSON (#{e.message}) — body=#{body.truncate(300)}"
    end

    def throttle!(kind)
      delay = (kind == :slow ? SLOW_DELAY : FAST_DELAY)
      last = @last_request_at[kind]
      if last
        wait = delay - (Time.zone.now - last)
        sleep(wait) if wait.positive?
      end
      @last_request_at[kind] = Time.zone.now
    end
  end
end
