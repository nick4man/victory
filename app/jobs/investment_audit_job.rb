# frozen_string_literal: true

# Background worker for `POST /valuations/audit`. Calls audit-engine-v2 in
# sequence (create_audit → run_monte_carlo → compare_offers → fetch_pdf is
# done on-demand later) and broadcasts the result over ValuationChannel so
# the frontend can pivot from loader to result without a full page reload.
#
# Retries:
#   UnavailableError (engine 5xx, timeout, circuit open) → Sidekiq retries
#     3 times with backoff. After retries exhausted, status → :failed.
#   ResponseError (engine 4xx) → terminal; bad payload, no retry.
class InvestmentAuditJob < ApplicationJob
  queue_as :default

  retry_on AuditEngine::UnavailableError, wait: 30.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(valuation_id, simulations: 1_000_000)
    valuation = PropertyValuation.find(valuation_id)
    return if valuation.completed? || valuation.failed?

    client = AuditEngine::Client.new
    payload = AuditEngine::AuditRequest.from_valuation(valuation)

    audit = client.create_audit(payload)
    audit_id = audit['id'] || audit[:id]
    raise AuditEngine::Error, 'engine returned no audit id' unless audit_id

    # Engine commit-vs-response race: occasionally the audit row isn't
    # visible to a follow-up session for a beat after create_audit returns
    # 200. Small backoff before MC avoids a 404 that would otherwise
    # propagate as ResponseError and fail the job terminally.
    mc = with_audit_lookup_retry(audit_id) do
      client.run_monte_carlo(audit_id, num_simulations: simulations)
    end

    # compare_offers can fail (no bank_offers seeded yet, or it costs MC).
    # We treat it as optional — if it 5xx's, we still complete the audit.
    offers = safe_compare_offers(client, audit_id)

    # Merge engine-side results into existing evaluation_data so any
    # source_* telemetry attached by the controller / chat-tool survives.
    existing = valuation.evaluation_data || {}
    valuation.update!(
      status: :completed,
      audit_engine_id: audit_id,
      evaluation_data: existing.merge(
        'audit' => audit,
        'monte_carlo' => mc,
        'bank_offers' => offers,
        'completed_at' => Time.current.iso8601
      )
    )

    # B2: snapshot exchange rates + visa chapter для foreign audits.
    # Snapshot курсов чтобы PDF rendered через дни не плавал; visa-chapter
    # генерируется LLM один раз и кэшируется в metadata. Best-effort —
    # не ломаем completion если внешний API упал.
    enrich_for_foreign_audit(valuation)

    ValuationChannel.broadcast_to(valuation, {
      status: 'completed',
      token: valuation.token,
      verdict: (audit['verdict'] || audit[:verdict])
    })

    # Fire-and-forget Telegram dispatch — PDF + visitor contacts + verdict
    # to staff channel. Failure inside the notifier is swallowed so it
    # can't roll back the completed audit state.
    AuditReportNotifier.notify(valuation)
  rescue AuditEngine::ResponseError => e
    existing = valuation.evaluation_data || {}
    valuation.update!(
      status: :failed,
      evaluation_data: existing.merge(
        'error' => { 'kind' => 'response', 'status' => e.status, 'body' => e.body }
      )
    )
    ValuationChannel.broadcast_to(valuation, {
      status: 'failed',
      token: valuation.token,
      error: e.message
    })
    Rails.logger.warn("[InvestmentAuditJob] #{valuation_id} → #{e.message}")
  end

  private

  # B2: Foreign-audit enrichment.
  # - Snapshot exchange rates → metadata['exchange_rates'] (PDF не плавает).
  # - LLM-generated visa/residency chapter → metadata['visa_chapter_en'].
  # Идемпотентно: skip если уже есть; soft-fail (рейзов нет).
  def enrich_for_foreign_audit(valuation)
    return unless valuation.metadata&.[]('audit_locale').to_s == 'en'

    meta = valuation.metadata.deep_dup
    changed = false

    # 1) Exchange rates snapshot (если ещё нет)
    if meta['exchange_rates'].blank?
      rates = CurrencyRatesService.call
      if rates.is_a?(Hash) && rates[:usd].present?
        # Convert symbol-keyed → string-keyed для jsonb persistence.
        meta['exchange_rates'] = rates.transform_keys(&:to_s)
        changed = true
      end
    end

    # 2) Visa/residency chapter (LLM, free-first chain)
    if meta['visa_chapter_en'].blank?
      content = AuditPdf::VisaResidencyContentGenerator.call(valuation)
      if content.present?
        meta['visa_chapter_en'] = content
        changed = true
      end
    end

    valuation.update_columns(metadata: meta) if changed
  rescue StandardError => e
    Rails.logger.warn("[InvestmentAuditJob#enrich_for_foreign_audit] #{e.class}: #{e.message}")
  end

  def safe_compare_offers(client, audit_id)
    with_audit_lookup_retry(audit_id) do
      client.compare_offers(audit_id, num_simulations: 100_000)
    end
  rescue AuditEngine::Error => e
    Rails.logger.info("[InvestmentAuditJob] compare_offers skipped: #{e.message}")
    nil
  end

  # Retry on ResponseError(404) only — engine commit lag, not a permanent
  # failure. Up to 3 attempts with 1s/2s/4s sleeps (max ~7s total).
  def with_audit_lookup_retry(audit_id, attempts: 3)
    tries = 0
    begin
      tries += 1
      yield
    rescue AuditEngine::ResponseError => e
      raise unless e.status == 404 && tries < attempts
      sleep_for = (2**(tries - 1)).to_f
      Rails.logger.info(
        "[InvestmentAuditJob] audit #{audit_id} not yet visible (try #{tries}/#{attempts}); " \
        "sleeping #{sleep_for}s"
      )
      sleep sleep_for
      retry
    end
  end
end
