import { Controller } from "@hotwired/stimulus"

// NOTE: This file is currently DEAD CODE — importmap-rails is disabled in
// this project (see app/views/layouts/application.html.erb lines 41-44),
// so Stimulus is never instantiated and no controllers register. The
// equivalent polling logic lives inline in
// app/views/valuations/investment/show.html.erb as a vanilla <script>.
//
// Kept here for the day Stimulus gets wired up sitewide — at that point,
// flip the show template to use data-controller="valuation-progress" and
// drop the inline <script>.
//
// Polls /valuations/audit/:token/status every 4 seconds while the audit is
// pending. Reloads the page once the engine flips status to completed or
// failed. ActionCable WebSocket integration is deferred until the
// app-wide consumer.js setup is fixed (chat_controller currently imports
// from a missing path — Phase 4.5 cleanup).
//
// Why 4s: typical InvestmentAuditJob takes 20-40s (1M MC + bank offers).
// 4s gives 5-10 polls — cheap on /status (single SQL select), good UX.
export default class extends Controller {
  static values = { token: String, status: String }
  static targets = ["loader", "poll"]

  POLL_INTERVAL_MS = 4_000
  MAX_DURATION_MS = 180_000   // 3 min safety stop

  connect() {
    if (this.statusValue !== "pending") return

    this.startedAt = Date.now()
    this.setPollText("Считаем...")
    this.timer = setInterval(() => this.poll(), this.POLL_INTERVAL_MS)
    // Run one immediately so we don't show "Ожидание..." for 4s when the job
    // already finished between server render and JS boot.
    this.poll()
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  async poll() {
    if (Date.now() - this.startedAt > this.MAX_DURATION_MS) {
      clearInterval(this.timer)
      this.setPollText("Превышено время ожидания. Обновите страницу.")
      return
    }

    try {
      const res = await fetch(`/valuations/audit/${this.tokenValue}/status`, {
        headers: { Accept: "application/json" },
      })
      if (!res.ok) return
      const data = await res.json()

      if (data.status === "completed" || data.status === "failed") {
        clearInterval(this.timer)
        this.setPollText("Готово, перезагружаем...")
        setTimeout(() => window.location.reload(), 400)
      }
    } catch (err) {
      console.warn("[valuation-progress] poll failed", err)
    }
  }

  setPollText(text) {
    if (this.hasPollTarget) this.pollTarget.textContent = text
  }
}
