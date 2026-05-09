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

    def initialize(api_key: ENV['TOPNLAB_API_KEY'], base_url: ENV['TOPNLAB_BASE_URL'])
      raise Error, 'TOPNLAB_API_KEY missing' if api_key.blank?
      raise Error, 'TOPNLAB_BASE_URL missing' if base_url.blank?

      @api_key = api_key
      @base_url = base_url.chomp('/')
      @last_request_at = {}
    end

    # GET /public/get-ids
    # @return [Array<Integer>]
    def get_ids(type:, action: nil, realty_type: nil, is_feed: nil, **filters)
      params = filters.merge(key: @api_key, type: type)
      params[:action] = action if action
      params[:realty_type] = realty_type if realty_type
      params[:is_feed] = is_feed unless is_feed.nil?

      data = http_get('/get-ids', params, throttle: :slow)
      data.is_a?(Array) ? data : []
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

    # POST /public/get-entities  with patch[] body — update fc_* custom fields on an entity.
    def patch_entity(id:, type:, fields:)
      http_post_json('/get-entities',
                     id: id, key: @api_key, type: type,
                     patch: [{ id: id, data: fields }])
    end

    private

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
        Rails.logger.warn("Topnlab #{label}: 404 not found"); nil
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
        wait = delay - (Time.now - last)
        sleep(wait) if wait.positive?
      end
      @last_request_at[kind] = Time.now
    end
  end
end
