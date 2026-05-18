# frozen_string_literal: true

# Phase 4E — Async lead intake из Topnlab webhook event.
#
# Контракт:
#   1. TopnlabController#create получает webhook order event
#   2. Enqueues TopnlabOrdersSyncJob (sync БД with latest order data)
#   3. Enqueues this job (TopnlabCrmIntakeJob)
#   4. Job waits для БД sync (BuyerOrder created/updated), затем Lead::Intake
#
# Why async + 30s delay: TopnlabOrdersSyncJob does full sweep (~30s), а
# BuyerOrder создаётся только в конце. Job без delay не найдёт BuyerOrder
# по crm_id и упадёт в skip. 30s delay achieves eventual consistency.
#
# Idempotency: Lead::Intake::CrmWebhookSource sam проверяет existing
# Inquiry через ClientResolver — повторный intake одного и того же
# order → no new LeadEvent.
class TopnlabCrmIntakeJob < ApplicationJob
  queue_as :scheduled

  def perform(order_id, delay_applied: false)
    # Wait для BuyerOrder sync если ещё не задержали
    unless delay_applied
      self.class.set(wait: 30.seconds).perform_later(order_id, delay_applied: true)
      Rails.logger.info("[TopnlabCrmIntakeJob] re-queued with 30s delay for order_id=#{order_id}")
      return
    end

    Rails.logger.info("[TopnlabCrmIntakeJob] processing order_id=#{order_id}")

    result = Lead::Intake.call(
      source: 'crm_webhook',
      payload: { id: order_id.to_s }
    )

    if result.success?
      if result.lead_event
        Rails.logger.info(
          "[TopnlabCrmIntakeJob] order_id=#{order_id} → LeadEvent##{result.lead_event.id} created"
        )
      else
        Rails.logger.info(
          "[TopnlabCrmIntakeJob] order_id=#{order_id} → no LeadEvent (matched existing OR skipped)"
        )
      end
    else
      Rails.logger.warn("[TopnlabCrmIntakeJob] order_id=#{order_id} failed: #{result.error}")
    end
  end
end
