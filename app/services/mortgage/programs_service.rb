# frozen_string_literal: true

module Mortgage
  # Read-through cache for the audit-engine bank-offers catalog. The engine
  # is source of truth (22+ programs seeded via scripts/seed_bank_offers.py);
  # we cache for 6 hours so the public /services/mortgage page renders
  # without an upstream call on every hit, and so a flapping engine doesn't
  # blank the programs table.
  class ProgramsService
    CACHE_KEY = 'mortgage:programs:v1'
    CACHE_TTL = 6.hours

    PRODUCT_TYPES = {
      'ready'         => 'Готовое жильё',
      'primary'       => 'Новостройка',
      'family'        => 'Семейная',
      'it'            => 'IT-ипотека',
      'rural'         => 'Сельская',
      'far_east'      => 'Дальневосточная',
      'consumer'      => 'Потребительский кредит'
    }.freeze

    class << self
      def all
        Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { fetch_from_engine }
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
