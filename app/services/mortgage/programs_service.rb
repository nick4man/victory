# frozen_string_literal: true

module Mortgage
  # Read-through cache for the audit-engine bank-offers catalog. The engine
  # is source of truth (22+ programs seeded via scripts/seed_bank_offers.py);
  # we cache for 6 hours so the public /services/mortgage page renders
  # without an upstream call on every hit, and so a flapping engine doesn't
  # blank the programs table.
  class ProgramsService
    CACHE_KEY       = 'mortgage:programs:v1'
    STALE_CACHE_KEY = 'mortgage:programs:stale:v1'
    CACHE_TTL       = 6.hours
    STALE_TTL       = 7.days  # keep last-good list around for engine-down windows

    # Engine values from BankProductType enum (Python side) → Russian
    # display label. Engine product_type comes verbatim from the DB; we
    # normalise here so the view doesn't need to know the wire values.
    # If a new product type appears in the engine, add it here AND in the
    # Python BankProductType enum.
    PRODUCT_TYPES = {
      'mortgage'           => 'Готовое жильё',
      'family_mortgage'    => 'Семейная ипотека',
      'it_mortgage'        => 'IT-ипотека',
      'subsidized'         => 'Господдержка',
      'refinance'          => 'Рефинансирование',
      'consumer_loan'      => 'Потребительский кредит',
      'far_east_mortgage'  => 'Дальневосточная ипотека',
      'military_mortgage'  => 'Военная ипотека',
      'deposit'            => 'Депозит',
      # Legacy short labels (kept for back-compat if any old caller passes them)
      'ready'              => 'Готовое жильё',
      'primary'            => 'Новостройка',
      'family'             => 'Семейная',
      'it'                 => 'IT-ипотека',
      'rural'              => 'Сельская',
      'far_east'           => 'Дальневосточная',
      'consumer'           => 'Потребительский кредит'
    }.freeze

    class << self
      # Fresh cache → 6h. If fresh is missing AND engine call fails,
      # fall back to the long-lived stale snapshot so the page keeps
      # rendering programs through brief engine outages.
      def all
        cached = Rails.cache.read(CACHE_KEY)
        return cached if cached.is_a?(Array) && cached.any?

        fresh = fetch_from_engine
        if fresh.any?
          Rails.cache.write(CACHE_KEY, fresh, expires_in: CACHE_TTL)
          Rails.cache.write(STALE_CACHE_KEY, fresh, expires_in: STALE_TTL)
          fresh
        else
          stale = Rails.cache.read(STALE_CACHE_KEY)
          stale.is_a?(Array) ? stale : []
        end
      end

      def find(id)
        all.find { |p| p[:id].to_s == id.to_s }
      end

      def by_type(type)
        return all if type.blank? || type == 'all'
        all.select { |p| p[:product_type].to_s == type.to_s }
      end

      def bust!
        Rails.cache.delete(CACHE_KEY)
        # Keep STALE_CACHE_KEY — bust! forces re-fetch but preserves
        # the safety net for the next request if the engine is down.
      end

      # Force-reset everything including the stale snapshot. Use after
      # major catalog migrations when the old shape would break the view.
      def hard_bust!
        Rails.cache.delete(CACHE_KEY)
        Rails.cache.delete(STALE_CACHE_KEY)
      end

      private

      def fetch_from_engine
        data = AuditEngine::Client.new.bank_offers_list(active: true)
        Array(data).map { |row| normalize(row) }.sort_by { |p| [p[:bank_name].to_s, p[:rate_min].to_f] }
      rescue AuditEngine::UnavailableError => e
        Rails.logger.warn("[Mortgage::ProgramsService] engine unavailable: #{e.message}")
        []
      end

      # Normalize keys to symbols + flatten any nested structures the engine
      # may add later. Returns a stable shape for views/controllers.
      def normalize(row)
        h = row.respond_to?(:symbolize_keys) ? row.symbolize_keys : row.transform_keys(&:to_sym)
        {
          id:                   h[:id],
          bank_name:            h[:bank_name],
          product_name:         h[:product_name],
          product_type:         h[:product_type],
          product_type_ru:      PRODUCT_TYPES[h[:product_type].to_s] || h[:product_type].to_s.titleize,
          rate_min:             h[:rate_min]&.to_f,
          rate_max:             h[:rate_max]&.to_f,
          term_years_min:       h[:term_years_min]&.to_i,
          term_years_max:       h[:term_years_max]&.to_i,
          down_payment_min_pct: h[:down_payment_min_pct]&.to_f,
          max_loan_amount:      h[:max_loan_amount]&.to_i,
          requirements:         h[:requirements],
          source_url:           h[:source_url],
          active:               h.fetch(:active, true)
        }
      end
    end
  end
end
