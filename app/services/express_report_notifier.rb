# frozen_string_literal: true

# Pushes a completed Express valuation (PropertyValuation.audit_mode == :express)
# to staff Telegram — same pattern as AuditReportNotifier from Phase 4.6.
# Sends summary HTML message first, then attaches the PDF as a document.
# Both calls are best-effort: any failure is logged but never re-raised,
# because the user has already received their on-screen result.
class ExpressReportNotifier
  def self.notify(valuation)
    new(valuation).deliver
  rescue StandardError => e
    Rails.logger.warn("[ExpressReportNotifier] #{e.class}: #{e.message}")
    nil
  end

  def initialize(valuation)
    @v = valuation
  end

  def deliver
    chat_id = ENV['TELEGRAM_VALUATIONS_CHAT_ID'].presence ||
              ENV['TELEGRAM_STAFF_CHAT_ID'].presence
    token   = ENV['TELEGRAM_BOT_TOKEN'].to_s
    return false if chat_id.blank? || token.empty?

    client = Telegram::Client.new(token: token)
    client.send_message(summary_text, chat_id: chat_id, parse_mode: 'HTML',
                        disable_web_page_preview: true)
    send_pdf(client, chat_id)
    true
  end

  private

  def send_pdf(client, chat_id)
    pdf_bytes = PdfGeneratorService.new(@v).call
    io = StringIO.new(pdf_bytes)
    client.send_document(
      { io: io, filename: "valuation-#{@v.report_number || @v.token}.pdf",
        content_type: 'application/pdf' },
      chat_id: chat_id,
      caption: "Экспресс-оценка #{@v.report_label}"
    )
  rescue StandardError => e
    Rails.logger.warn("[ExpressReportNotifier] PDF dispatch failed: #{e.class} #{e.message}")
  end

  def summary_text
    lines = []
    lines << "📐 <b>Экспресс-оценка #{escape(@v.report_label)}</b>"
    lines << ''
    lines << contact_block.presence || '👤 <i>анонимно (контакты не оставлены)</i>'
    lines << ''
    lines << '🏠 <b>Объект</b>'
    lines << "  · #{escape(@v.address.to_s)}"
    lines << "  · #{property_type_ru} · #{@v.total_area || @v.land_area || '—'} #{@v.land_area && !@v.total_area ? 'соток' : 'м²'}"
    lines << ''
    if @v.estimated_price.present?
      lines << '💰 <b>Оценка</b>'
      lines << "  · Рыночная: <b>#{fmt_rub(@v.estimated_price)}</b>"
      if @v.min_price.present? && @v.max_price.present?
        lines << "  · Диапазон: #{fmt_rub(@v.min_price)} – #{fmt_rub(@v.max_price)}"
      end
      lines << "  · Достоверность: #{((@v.confidence_level || 0).to_f * 100).round}%" if @v.confidence_level
    end
    base = ENV['APP_URL'].presence || (defined?(AgencyInfo) ? AgencyInfo::WEBSITE_URL : 'https://victory62.org')
    lines << ''
    lines << %(🔗 <a href="#{base}/valuations/#{@v.token}/result">Открыть отчёт</a>)
    lines.join("\n")
  end

  def contact_block
    name  = @v.name.presence
    email = @v.email.presence
    phone = @v.phone.presence
    return nil if name.blank? && email.blank? && phone.blank?
    parts = ['👤 <b>Контакт</b>']
    parts << "  · #{escape(name)}"      if name
    parts << "  · 📞 #{escape(phone)}"   if phone
    parts << "  · ✉️ #{escape(email)}"    if email
    parts.join("\n")
  end

  PROPERTY_TYPE_RU = {
    'apartment'  => 'Квартира',
    'house'      => 'Дом',
    'land'       => 'Участок',
    'commercial' => 'Коммерческая',
    'garage'     => 'Гараж',
    'room'       => 'Комната'
  }.freeze

  def property_type_ru
    PROPERTY_TYPE_RU[@v.property_type.to_s] || @v.property_type.to_s.titleize
  end

  def fmt_rub(value)
    "#{value.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse} ₽"
  end

  def escape(s)
    s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end
end
