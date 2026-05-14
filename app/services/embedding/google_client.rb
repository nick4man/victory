# frozen_string_literal: true

require 'net/http'
require 'json'
require 'digest'

module Embedding
  # Net::HTTP client for Google's gemini-embedding-001 model.
  #
  # The model returns 3072-dim by default; we request outputDimensionality: 768
  # to use the Matryoshka-truncated head — preserves semantic quality with ~3-5%
  # benchmark loss while shrinking the pgvector index by 4x.
  #
  # Free tier: 100 requests/min. Paid tier: pennies per 1M tokens.
  #
  # Example:
  #   Embedding::GoogleClient.new.embed("Двушка в Левобережном с евроремонтом")
  #   #=> [0.0123, -0.0456, ...]  # 768 floats
  class GoogleClient
    class Error < StandardError; end

    DEFAULT_DIM   = 768
    MODEL         = 'gemini-embedding-001'
    BASE_URL      = 'https://generativelanguage.googleapis.com/v1beta'
    OPEN_TIMEOUT  = 15  # was 5 — cold TCP handshake from РФ to Google APIs
                       # routinely needs >5s; covered by 3-attempt retry now
    READ_TIMEOUT  = 30
    MAX_ATTEMPTS  = 3

    def initialize(api_key: ENV['GOOGLE_EMBEDDING_API_KEY'], dim: DEFAULT_DIM)
      raise Error, 'GOOGLE_EMBEDDING_API_KEY not set' if api_key.blank?

      @api_key = api_key
      @dim     = dim
    end

    # @param text [String]
    # @param cache [Boolean] (default: true) round-trip Rails.cache to dedupe
    #   identical query strings. Skip when re-embedding from a backfill task
    #   or when intentionally regenerating after a model change.
    # @return [Array<Float>] embedding of length @dim
    def embed(text, cache: true)
      raise Error, 'text must be non-empty' if text.to_s.strip.empty?

      if cache
        key = "embedding:#{MODEL}:#{@dim}:#{Digest::SHA256.hexdigest(text)}"
        cached = Rails.cache.read(key)
        return cached if cached.is_a?(Array) && cached.size == @dim

        vec = embed_uncached(text)
        Rails.cache.write(key, vec, expires_in: 1.day)
        vec
      else
        embed_uncached(text)
      end
    end

    def embed_uncached(text)
      payload = {
        model:                MODEL,
        content:              { parts: [{ text: text.to_s }] },
        outputDimensionality: @dim
      }
      attempt = 0
      begin
        attempt += 1
        post(payload)
      rescue Error, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, SocketError => e
        # OpenTimeout/ReadTimeout/ECONNRESET were not in the rescue list,
        # so a single cold TCP handshake stall (5s OPEN_TIMEOUT) used to
        # bubble up immediately. Now they participate in the retry chain
        # with exponential backoff (2 / 4 / 8s).
        if attempt >= MAX_ATTEMPTS
          raise e.is_a?(Error) ? e : Error.new("#{e.class}: #{e.message}")
        end
        sleep(2**attempt)
        retry
      end
    end

    private

    def post(payload)
      uri = URI("#{BASE_URL}/models/#{MODEL}:embedContent?key=#{@api_key}")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(payload)

      res = Net::HTTP.start(uri.host, uri.port,
                            use_ssl:      true,
                            open_timeout: OPEN_TIMEOUT,
                            read_timeout: READ_TIMEOUT) { |h| h.request(req) }

      raise Error, "HTTP #{res.code}: #{res.body.to_s.truncate(300)}" unless res.is_a?(Net::HTTPSuccess)

      values = JSON.parse(res.body).dig('embedding', 'values')
      raise Error, "no embedding.values in response: #{res.body.truncate(200)}" if values.blank?

      values
    end
  end
end
