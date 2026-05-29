# frozen_string_literal: true

module Lead
  class Intake
    # Phase 4H — Cross-channel client identity resolver.
    #
    # Problem: same human person может прийти через 3 разных канала
    # (site form → TG-DM → CRM manual). Без cross-matching мы create
    # 3 different Inquiries / LeadEvents — agent видит «новый лид»
    # каждый раз вместо continuous conversation.
    #
    # Solution: per-channel intake sources populate normalized identity
    # columns (client_phone_e164, client_tg_user_id, client_email_norm).
    # ClientResolver matches новый intake против existing Inquiries.
    #
    # Match priority (Confidence-graded):
    #   1. Exact phone E.164 match     — HIGH confidence (auto-merge)
    #   2. tg_user_id match             — HIGH confidence (одинаковый TG аккаунт)
    #   3. Exact email (normalized)     — MEDIUM (могут share email в семье)
    #   4. Fuzzy name + same phone last-4  — Phase 5+ (suggested merge UI)
    #
    # Window: 90 days. Older inquiries — closed flow, новый intake = новый
    # lead by design.
    #
    # Returns the most recent Inquiry that matches (sorted by created_at DESC)
    # OR nil. Does NOT modify; pure lookup. Caller responsible для merge/skip.
    class ClientResolver
      WINDOW = 90.days

      Result = Struct.new(:inquiry, :match_strategy, :confidence,
                          keyword_init: true) do
        def matched?
          !inquiry.nil?
        end
      end

      def self.find(...)
        new(...).find
      end

      def initialize(phone: nil, tg_user_id: nil, email: nil)
        @phone_e164  = normalize_phone(phone)
        @tg_user_id  = tg_user_id.presence
        @email_norm  = normalize_email(email)
      end

      def find
        # Priority 1: phone E.164 exact match
        if @phone_e164.present?
          match = recent_scope.where(client_phone_e164: @phone_e164).order(created_at: :desc).first
          return Result.new(inquiry: match, match_strategy: 'phone_e164', confidence: 0.95) if match
        end

        # Priority 2: tg_user_id exact match (same TG account)
        if @tg_user_id.present?
          match = recent_scope.where(client_tg_user_id: @tg_user_id).order(created_at: :desc).first
          return Result.new(inquiry: match, match_strategy: 'tg_user_id', confidence: 0.90) if match
        end

        # Priority 3: email normalized exact (medium confidence — family share email)
        if @email_norm.present?
          match = recent_scope.where(client_email_norm: @email_norm).order(created_at: :desc).first
          return Result.new(inquiry: match, match_strategy: 'email', confidence: 0.70) if match
        end

        Result.new(inquiry: nil, match_strategy: nil, confidence: 0.0)
      end

      # === Class-level utilities — переиспользуются по проекту ===

      # Phone → E.164-ish: 11 digits без +, "8" prefix → "7", 10 digits
      # prefixed with "7" (assume Russian numbering plan для local input).
      # Returns nil если input invalid (< 10 digits).
      def self.normalize_phone(phone)
        return nil if phone.blank?

        digits = phone.to_s.gsub(/\D/, '')
        return nil if digits.length < 10

        if digits.length == 10
          # Russian 10-digit без country code → prepend 7
          "7#{digits}"
        elsif digits.length == 11 && digits.start_with?('8')
          # 8-prefix Russian → 7-prefix E.164
          "7#{digits[1..]}"
        else
          # Already 11+ digits — take last 11 (handles + prefix bleed)
          digits[-11..]
        end
      end

      def self.normalize_email(email)
        e = email.to_s.strip.downcase
        e.match?(URI::MailTo::EMAIL_REGEXP) ? e : nil
      end

      private

      def normalize_phone(phone)
        self.class.normalize_phone(phone)
      end

      def normalize_email(email)
        self.class.normalize_email(email)
      end

      def recent_scope
        Inquiry.where('created_at > ?', WINDOW.ago)
               .where.not(status: %w[spam cancelled])
      end
    end
  end
end
