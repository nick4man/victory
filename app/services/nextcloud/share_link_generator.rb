# frozen_string_literal: true

require 'digest'
require 'securerandom'

module Nextcloud
  # Phase 7.8a — Генератор public share links для NC paths через OCS API.
  #
  # Idempotent: для одного path возвращает существующий active link (если
  # not expired); иначе создаёт fresh + сохраняет в `Nextcloud::ShareLink`.
  #
  # Password: 12 base32-chars auto-generated при первом создании. Хранится в
  # БД для re-display (Nextcloud `GET /shares/<id>` НЕ возвращает password).
  #
  # @example
  #   r = Nextcloud::ShareLinkGenerator.for(
  #     path: 'Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/<deal>/dossier.pdf',
  #     ttl: 7.days, created_by: tg_user
  #   )
  #   r.url        # => 'https://cloud.victory62.org/s/abcdef'
  #   r.password   # => 'XY3K7QM9PFNR'
  #   r.expires_at # => 2026-05-24
  class ShareLinkGenerator
    class Error < StandardError; end

    DEFAULT_TTL = 7.days

    Result = Struct.new(:url, :password, :expires_at, :nc_share_id, :token, :record,
                        keyword_init: true)

    def self.for(path:, **)
      new(path: path, **).call
    end

    def initialize(path:, ttl: DEFAULT_TTL, password: nil, created_by: nil,
                   client: Nextcloud::Client.new)
      @path       = path
      @ttl        = ttl
      @password   = password || generate_password
      @created_by = created_by
      @client     = client
    end

    def call
      @client.assert_safe_path!(@path)

      fingerprint = Nextcloud::ShareLink.fingerprint(@path)
      cached = Nextcloud::ShareLink.active.find_by(path_sha256: fingerprint)
      return result_from(cached) if cached && !cached.expired?

      expire_date = (Date.current + @ttl.to_i.seconds).to_date
      res = @client.create_share(path: @path, password: @password, expire_date: expire_date)
      raise Error, 'OCS create_share returned empty' if res.blank? || res[:url].blank?

      record = persist!(res, expire_date, fingerprint)
      result_from(record)
    end

    private

    def persist!(ocs_response, expire_date, fingerprint)
      Nextcloud::ShareLink.create!(
        path_sha256: fingerprint,
        path: @path,
        share_url: ocs_response[:url],
        share_token: ocs_response[:token],
        password: @password,
        nc_share_id: ocs_response[:id],
        expires_at: expire_date.to_time.end_of_day,
        created_by_id: @created_by&.id
      )
    end

    def result_from(record)
      Result.new(
        url: record.share_url,
        password: record.password,
        expires_at: record.expires_at,
        nc_share_id: record.nc_share_id,
        token: record.share_token,
        record: record
      )
    end

    # 12 символов: гарантированно по 1 из каждой категории (upper/lower/digit/special)
    # — Nextcloud password policy на проде требует mixed case + special char.
    # Алфавит без ambiguous chars (I/l/O/0/1).
    def generate_password
      upper   = 'ABCDEFGHJKMNPQRSTVWXYZ'.chars
      lower   = 'abcdefghjkmnpqrstvwxyz'.chars
      digits  = '23456789'.chars
      symbols = '!@#$%&*+-?'.chars
      required = [upper.sample, lower.sample, digits.sample, symbols.sample]
      pool = upper + lower + digits + symbols
      (required + Array.new(8) { pool.sample }).shuffle.join
    end
  end
end
