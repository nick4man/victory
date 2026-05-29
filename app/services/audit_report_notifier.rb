# frozen_string_literal: true

# Best-effort dispatch of a finished investment audit to staff Telegram —
# sends a structured message (contact + verdict + key metrics + property)
# followed by the generated PDF as a document.
#
# Pattern mirrors ReviewModerationNotifier:
#   - silent no-op when TELEGRAM_BOT_TOKEN / chat IDs aren't set
#   - any error is logged but does NOT raise (audit completion is the
#     primary concern; notification is a side-effect for staff awareness)
#
# Triggered from InvestmentAuditJob after the PropertyValuation is marked
# completed. Chat target precedence:
#   1. TELEGRAM_AUDITS_CHAT_ID (dedicated channel if set)
#   2. TELEGRAM_STAFF_CHAT_ID  (general staff channel)
class AuditReportNotifier
  def self.notify(valuation)
    new(valuation).call
  rescue StandardError => e
    Rails.logger.warn("[AuditReportNotifier] failed for #{valuation&.id}: #{e.class} #{e.message}")
    false
  end

  def initialize(valuation)
    @v     = valuation
    @audit = (valuation.evaluation_data || {})['audit'] || {}
    @mc    = (valuation.evaluation_data || {})['monte_carlo'] || {}
  end

  def call
    chat_id = ENV['TELEGRAM_AUDITS_CHAT_ID'].presence || ENV['TELEGRAM_STAFF_CHAT_ID'].presence
    return false if chat_id.blank? || ENV['TELEGRAM_BOT_TOKEN'].blank?

    client = Telegram::Client.new
    client.send_message(summary_message, chat_id: chat_id, parse_mode: 'HTML')
    send_pdf(client, chat_id)
    true
  end

  private

  def send_pdf(client, chat_id)
    pdf_bytes = AuditPdfGenerator.call(@v)
    require 'stringio'
    io = StringIO.new(pdf_bytes)
    client.send_document(
      { io: io, filename: "audit-#{@v.report_number || @v.token}.pdf", content_type: 'application/pdf' },
      chat_id: chat_id,
      caption: "PDF-отчёт #{@v.report_label} · #{verdict_ru}"
    )
  rescue StandardError => e
    # If PDF generation or upload fails, the summary message was already
    # delivered — staff still see the lead. Log and continue.
    Rails.logger.warn("[AuditReportNotifier] PDF dispatch failed: #{e.class} #{e.message}")
  end

  def summary_message
    lines = []
    lines << "📊 <b>Новый инвест-аудит #{escape(@v.report_label)} — #{verdict_ru}</b>"
    lines << ''
    lines << contact_block.presence || '👤 <i>анонимно (контакты не оставлены)</i>'
    lines << ''
    lines << "🏠 <b>Объект</b>"
    lines << "  · #{escape(address)}"
    lines << "  · #{area_text} · #{escape(fmt_rub(@audit['price_total']))}"
    if @v.evaluation_data&.dig('source_property_id')
      lines << "  · из каталога: <code>/properties/#{escape(@v.evaluation_data['source_property_slug'].to_s)}</code>"
    end
    lines << ''
    lines << '📈 <b>Эффективность инвестиций (EI)</b>'
    lines << "  · Наличными: <b>#{fmt2(@audit['ei_cash'])}</b>"
    lines << "  · Ипотека:   <b>#{fmt2(@audit['ei_mortgage'])}</b>"
    lines << "  · Депозит:   <b>#{fmt2(@audit['ei_deposit'])}</b>"
    if (rec = @mc['recommended_strategy']).present?
      lines << "  · MC рекомендует: <b>#{strategy_ru(rec)}</b>"
    end
    if @audit['verdict_explanation'].present?
      lines << ''
      lines << "💬 #{escape(@audit['verdict_explanation'].to_s.truncate(280))}"
    end
    lines << ''
    base = ENV['APP_URL'].presence || AgencyInfo::WEBSITE_URL
    lines << %(🔗 <a href="#{base}/valuations/audit/#{@v.token}">Открыть отчёт</a>)
    lines << "🛠 Канал: #{source_label}"
    lines.join("\n")
  end

  def contact_block
    name  = @v.name.presence
    email = @v.email.presence
    phone = @v.phone.presence
    return nil if name.blank? && email.blank? && phone.blank?

    lines = ['👤 <b>Контакт</b>']
    lines << "  · #{escape(name)}" if name
    lines << "  · ☎ #{escape(phone)}" if phone
    lines << "  · ✉ #{escape(email)}" if email
    lines.join("\n")
  end

  def source_label
    case @v.evaluation_data&.dig('source')
    when 'chat_bot'           then 'чат-бот'
    when 'property_show_cta'  then 'кнопка на странице объекта'
    when nil                  then 'форма /valuations/audit'
    else                           @v.evaluation_data['source'].to_s
    end
  end

  def address
    (@v.address.presence || @audit['complex_name']).to_s
  end

  def area_text
    a = @audit['area_sqm']&.to_f
    a&.positive? ? "#{a.round(1)} м²" : '—'
  end

  def verdict_ru
    { 'BUY' => 'ПОКУПАТЬ', 'WAIT' => 'ПОДОЖДАТЬ', 'NEUTRAL' => 'НЕЙТРАЛЬНО' }
      .fetch(@audit['verdict'].to_s, @audit['verdict'].to_s)
  end

  def strategy_ru(key)
    { 'cash' => 'Наличными', 'mortgage' => 'Ипотека', 'deposit' => 'Депозит' }
      .fetch(key.to_s, key.to_s.capitalize)
  end

  def fmt2(v)
    v.blank? ? '—' : v.to_f.round(2).to_s
  end

  def fmt_rub(v)
    return '—' if v.blank?
    "#{v.to_f.round.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse} ₽"
  end

  def escape(text)
    text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end
end
