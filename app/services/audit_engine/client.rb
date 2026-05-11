# frozen_string_literal: true

require 'faraday'
require 'faraday/retry'
require 'stoplight'

module AuditEngine
  # Thin Faraday wrapper around the audit-engine-v2 sidecar API (see
  # `services/audit-engine/SKILL_API_CONTRACT.md`). All public methods are
  # wrapped in a Stoplight circuit breaker keyed on 'audit-engine' so a
  # flapping or dead engine fails fast (UnavailableError) instead of
  # exhausting Puma threads on 30-second timeouts.
  #
  # Auth: sends `X-Audit-Token: $AUDIT_API_TOKEN` (set in .env, must match
  # one of AUDIT_API_TOKENS in .env.audit). If unset, the engine accepts
  # anonymous requests (backwards-compat mode) — fine in dev, not prod.
  #
  # Errors:
  #   - AuditEngine::ResponseError  — 4xx (do not retry; bug in payload)
  #   - UnavailableError — 5xx, timeout, circuit-open (Sidekiq retries)
  class Client
    DEFAULT_TIMEOUT = 30 # seconds — covers cold uvicorn imports + macro fetch
    DEFAULT_OPEN_TIMEOUT = 5

    CIRCUIT_NAME = 'audit-engine'
    CIRCUIT_THRESHOLD = 3      # 3 failures → open
    CIRCUIT_COOL_OFF = 60      # seconds before half-open probe

    def initialize(base_url: nil, token: nil, timeout: DEFAULT_TIMEOUT)
      url = base_url || ENV.fetch('AUDIT_API_BASE_URL', 'http://audit-api:8000/api/v2')
      # Faraday treats relative paths as appended to base only when base ends in
      # a trailing slash; otherwise the last segment is replaced. Normalise so
      # the rest of this class can use leading-slash-free paths consistently.
      @base_url = url.end_with?('/') ? url : "#{url}/"
      @token    = token || ENV['AUDIT_API_TOKEN']
      @timeout  = timeout
    end

    # GET /health — also doubles as our liveness probe from Rails.
    def health
      request { connection.get('health') }
    end

    # POST /audit/ — creates a new audit, returns the full AuditResult hash
    # including `id` (UUID) used in subsequent /audit/{id}/* calls.
    # `payload` is built by AuditEngine::AuditRequest.from_valuation.
    def create_audit(payload)
      request { connection.post('audit/', payload) }
    end

    # POST /audit/{id}/monte-carlo — runs full 3-strategy MC. 1M sims ≈ 14s
    # CPU; the Sidekiq InvestmentAuditJob is what calls this so Puma is not
    # blocked. `num_simulations` ceiling is 1_000_000 (engine returns 413
    # above that — see SKILL_API_CONTRACT.md §4.2).
    def run_monte_carlo(audit_id, num_simulations: 1_000_000, seed: nil)
      request do
        connection.post("audit/#{audit_id}/monte-carlo") do |req|
          req.params['num_simulations'] = num_simulations
          req.params['seed'] = seed if seed
        end
      end
    end

    # POST /audit/{id}/compare-offers — multi-offer MC across bank-offers
    # catalog. Returns top-N mortgage scenarios sorted by EI. Cheap enough
    # (`num_simulations` default 100k) to call inline after create_audit.
    def compare_offers(audit_id, num_simulations: 100_000, limit: 10)
      request do
        connection.post("audit/#{audit_id}/compare-offers") do |req|
          req.params['num_simulations'] = num_simulations
          req.params['limit'] = limit
        end
      end
    end

    # GET /audit/{id} — refetch full audit by id (used by show controller
    # when we already have an audit_engine_id stored locally).
    def fetch_audit(audit_id)
      request { connection.get("audit/#{audit_id}") }
    end

    # GET /audit/{id}/location-score — returns nil if engine has no lat/lon
    # for the audit (404 surfaces here as ResponseError; we swallow and nil-out).
    def fetch_location_score(audit_id)
      request { connection.get("audit/#{audit_id}/location-score") }
    rescue AuditEngine::ResponseError => e
      raise unless e.status == 404
      nil
    end

    # GET /macro/latest — current CB-RF key rate, derived mortgage/deposit
    # rates, inflation. Engine updates this via APScheduler cron; cache
    # downstream as needed.
    def macro_latest
      request { connection.get('macro/latest') }
    end

    # GET /bank-offers/ — full catalog of seeded mortgage programs (22+ from
    # Сбер/ВТБ/Альфа/Газпром/etc). Source of truth for the calculator's
    # programs table at /services/mortgage. Cached downstream by
    # Mortgage::ProgramsService (Redis, 6h) — engine roundtrip is cheap but
    # this endpoint changes only on seed-script re-run.
    def bank_offers_list(active: true)
      request { connection.get('bank-offers/') { |req| req.params['active'] = active } }
    end

    # GET /audit/{id}/pdf — streams the branded PDF report. Returned value
    # is the binary body string; Rails controller should `send_data` it.
    # Engine generates via WeasyPrint+Plotly so this is the slowest
    # endpoint (~3-5s).
    def fetch_pdf(audit_id)
      response = raw_request do
        connection.get("audit/#{audit_id}/pdf") do |req|
          req.options.timeout = 60
        end
      end
      raise AuditEngine::ResponseError.new(response.status, response.body) unless response.success?
      response.body
    end

    private

    def connection
      @connection ||= Faraday.new(url: @base_url) do |f|
        f.request :json
        f.request :retry,
                  max: 2,
                  interval: 1,
                  backoff_factor: 2,
                  retry_statuses: [502, 503, 504],
                  exceptions: [
                    Faraday::TimeoutError,
                    Faraday::ConnectionFailed,
                    Errno::ECONNREFUSED
                  ]
        f.response :json, content_type: /\bjson$/
        f.options.timeout = @timeout
        f.options.open_timeout = DEFAULT_OPEN_TIMEOUT
        f.headers['X-Audit-Token'] = @token if @token.present?
        f.adapter Faraday.default_adapter
      end
    end

    # Wrapping pattern is split into two layers so the circuit breaker only
    # sees signals of engine unavailability (timeout, conn refused, 5xx) —
    # not application-level 4xx errors. Otherwise a flood of validation
    # errors (e.g. bad payload from one buggy form) would trip the breaker
    # and lock out healthy callers for 60 seconds.
    #
    # `request { ... }` returns the parsed body on 2xx, raises ResponseError
    # on 4xx (outside breaker — doesn't count), raises UnavailableError on
    # 5xx (inside breaker — does count toward threshold).
    def request(&block)
      response = raw_request(&block)
      return response.body if response.success?
      # Reached here only for 4xx — 5xx was already converted to UnavailableError
      # inside raw_request and the breaker re-raises it.
      raise AuditEngine::ResponseError.new(response.status, response.body)
    end

    # `raw_request` runs the HTTP call inside the Stoplight breaker. Only
    # 5xx and connection-level errors are raised inside the breaker (so
    # they're counted). 4xx returns normally — the wrapping `request` lifts
    # them into ResponseError outside the breaker.
    def raw_request
      Stoplight(CIRCUIT_NAME)
        .with_threshold(CIRCUIT_THRESHOLD)
        .with_cool_off_time(CIRCUIT_COOL_OFF)
        .with_fallback do |_error|
          raise AuditEngine::UnavailableError,
                'audit-engine circuit open (recent failures exceeded threshold)'
        end
        .run do
          resp = yield
          if resp.status >= 500
            raise AuditEngine::UnavailableError,
                  "audit-engine #{resp.status}: #{truncate(resp.body)}"
          end
          resp
        end
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Errno::ECONNREFUSED => e
      raise AuditEngine::UnavailableError,
            "audit-engine network error: #{e.class} #{e.message}"
    end

    def truncate(body)
      body.is_a?(Hash) ? body.to_json[0, 500] : body.to_s[0, 500]
    end
  end
end
