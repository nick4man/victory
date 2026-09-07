# frozen_string_literal: true

module DocumentChecklist
  # Phase 4F — Pure-logic assessor для ramping document reminders.
  # No side-effects, just decides which tier action нужен для DocumentRequirement.
  #
  # Tier ladder (ramping cadence):
  #   Tier 1 (client_gentle):   overdue_factor >= 1.0  AND last_reminder >= 24h ago
  #   Tier 2 (manager_dm):      overdue_factor >= 2.0  AND last_reminder >= 24h ago
  #   Tier 3 (director_cascade): overdue_factor >= 3.0  AND last_reminder >= 48h ago
  #
  # Tier 3 overrides tier 2 overrides tier 1 — выбираем highest applicable.
  # Re-windowing per-tier — клиент получит gentle reminder каждые 24h max,
  # manager — раз в 24h на overdue 2x+, director — раз в 48h на 3x+.
  #
  # Skips:
  #   • Weekend (Sat/Sun) — Phase 4 design choice: weekend doesn't count
  #     toward SLA, no reminders. Bus dev work-week-driven, не calendar-day.
  #   • Status final (verified/approved/rejected) — already resolved
  #   • No requested_at — невозможно посчитать overdue_factor
  #
  # @example
  #   assessment = DocumentChecklist::SlaAssessor.assess(dr)
  #   assessment.tier              # → 1, 2, 3, or nil
  #   assessment.tier_name         # → 'client_gentle' / 'manager_dm' / 'director_cascade' / nil
  #   assessment.reason            # → human-readable why-tier OR skip-reason
  class SlaAssessor
    TIER_NAMES = { 1 => 'client_gentle', 2 => 'manager_dm', 3 => 'director_cascade' }.freeze
    TIER_REWINDOW = { 1 => 24.hours, 2 => 24.hours, 3 => 48.hours }.freeze
    TIER_OVERDUE_THRESHOLD = { 1 => 1.0, 2 => 2.0, 3 => 3.0 }.freeze

    Assessment = Struct.new(:tier, :tier_name, :reason, :overdue_factor,
                            keyword_init: true) do
      def actionable?
        !tier.nil?
      end
    end

    def self.assess(requirement, now: Time.current)
      new(requirement, now: now).assess
    end

    def initialize(requirement, now: Time.current)
      @dr = requirement
      @now = now
    end

    def assess
      # Final statuses — done.
      if %w[verified approved rejected].include?(@dr.status)
        return Assessment.new(reason: "status=#{@dr.status} (final)")
      end

      # Need requested_at to measure overdue.
      if @dr.requested_at.blank?
        return Assessment.new(reason: 'no requested_at — not actionable')
      end

      # Weekend pause: Saturday or Sunday — skip.
      # Choice: weekend doesn't count toward SLA in this model.
      if weekend?(@now)
        return Assessment.new(reason: 'weekend skip')
      end

      # Именно @now, а не Time.current: иначе weekend-проверка и rewindow идут
      # по переданному времени, а фактор просрочки — по настоящему.
      factor = @dr.overdue_factor(now: @now) || 0.0

      # Determine highest applicable tier (3 → 2 → 1).
      tier = applicable_tier(factor)
      return Assessment.new(overdue_factor: factor, reason: "factor=#{factor.round(2)} below tier-1 threshold") if tier.nil?

      # Re-window check per-tier — last_reminder_at must be older than tier's rewindow OR nil.
      unless rewindow_elapsed?(tier)
        return Assessment.new(
          overdue_factor: factor,
          reason: "tier-#{tier} cooldown: last_reminder #{ago_str(@dr.last_reminder_at)} ago"
        )
      end

      Assessment.new(
        tier: tier,
        tier_name: TIER_NAMES[tier],
        overdue_factor: factor,
        reason: "factor=#{factor.round(2)} tier=#{tier}"
      )
    end

    private

    def weekend?(time)
      time.saturday? || time.sunday?
    end

    def applicable_tier(factor)
      # Highest tier whose threshold is satisfied.
      [3, 2, 1].find { |t| factor >= TIER_OVERDUE_THRESHOLD[t] }
    end

    def rewindow_elapsed?(tier)
      last = @dr.last_reminder_at
      return true if last.blank?

      window = TIER_REWINDOW[tier]
      (@now - last) >= window
    end

    def ago_str(time)
      return 'never' if time.blank?

      seconds = (@now - time).to_i
      return "#{seconds}s" if seconds < 60
      return "#{(seconds / 60.0).round}min" if seconds < 3600
      return "#{(seconds / 3600.0).round(1)}h" if seconds < 86_400

      "#{(seconds / 86_400.0).round(1)}d"
    end
  end
end
