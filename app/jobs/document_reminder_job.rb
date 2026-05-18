# frozen_string_literal: true

# Phase 4F — Hourly cron job для document SLA reminders.
#
# Scope: DocumentRequirement.status IN [requested, received] AND
#        requested_at < 24h ago (heuristic: factor>=1.0 requires
#        at least requested_at < SLA elapsed; partial index
#        idx_doc_req_sla_assessor поддерживает hot query).
#
# Per-record: SlaAssessor → tier (1/2/3) или skip. Если actionable —
# ReminderSender отправляет DM соответствующего tier.
#
# Quiet hours (21:00-07:00 MSK) — НЕ skip-ит entire job, а только defer
# отправку до 07:00 next morning. Tier-1 client gentle особенно
# важно не слать ночью (waking up клиента — anti-pattern).
#
# Concurrency: AlertThrottle key per (lead_id, dr_id, tier) — fail-safe
# даже если cron двойной trigger.
class DocumentReminderJob < ApplicationJob
  queue_as :scheduled

  BATCH_LIMIT = 200 # safety upper bound per run

  def perform
    return :quiet_hours_skip if quiet_hours_active?

    candidates = DocumentRequirement
                 .where(status: %w[requested received])
                 .where.not(requested_at: nil)
                 .where('requested_at < ?', 24.hours.ago)
                 .limit(BATCH_LIMIT)

    stats = { processed: 0, tier1: 0, tier2: 0, tier3: 0, skipped: 0, errors: 0 }

    candidates.find_each do |dr|
      stats[:processed] += 1
      assessment = DocumentChecklist::SlaAssessor.assess(dr)

      unless assessment.actionable?
        stats[:skipped] += 1
        next
      end

      result = DocumentChecklist::ReminderSender.call(
        requirement: dr,
        tier: assessment.tier
      )

      if result.success?
        stats[:"tier#{assessment.tier}".to_sym] += 1
        Rails.logger.info(
          "[DocumentReminderJob] dr##{dr.id} kind=#{dr.kind} tier=#{assessment.tier} sent → #{result.recipients_count} recipients"
        )
      else
        stats[:errors] += 1
        Rails.logger.warn(
          "[DocumentReminderJob] dr##{dr.id} tier=#{assessment.tier} failed: #{result.error}"
        )
      end
    end

    Rails.logger.info("[DocumentReminderJob] done: #{stats.inspect}")
    stats
  end

  private

  # Phase 3 QuietHours reuse — 21:00-07:00 MSK
  def quiet_hours_active?
    return false unless defined?(::Telegram::WorkBot::QuietHours)

    ::Telegram::WorkBot::QuietHours.active?
  end
end
