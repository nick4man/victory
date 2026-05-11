# frozen_string_literal: true

# Pushes a new mortgage Inquiry to staff Telegram (mirrors AuditReportNotifier
# from Phase 4.6). Includes the chosen bank program, audit context if any,
# and contact info. Failures are logged but never re-raised — the inquiry is
# already saved and we don't want to bounce the user with a 500 because
# Telegram is down.
class MortgageApplicationNotifier
  def self.notify(inquiry, program = nil)
    new(inquiry, program).deliver
  rescue StandardError => e
    Rails.logger.warn("[MortgageApplicationNotifier] failed: #{e.class} #{e.message}")
    nil
  end

  def initialize(inquiry, program)
    @inquiry = inquiry
    @program = program
  end

  def deliver
    chat_id = ENV['TELEGRAM_STAFF_CHAT_ID'].to_s
    token   = ENV['TELEGRAM_STAFF_BOT_TOKEN'].to_s
    return false if chat_id.empty? || token.empty?

    client = Telegram::Client.new(bot_token: token)
    client.send_message(text: summary_text, chat_id: chat_id, parse_mode: 'HTML', disable_web_page_preview: true)
    true
  end

  private

  def summary_text
    lines = []
    lines << "🏦 <b>Заявка на ипотеку №#{@inquiry.id}</b>"
    lines << ''
    if @program
      lines << "<b>Программа:</b> #{escape(@program[:bank_name])} · #{escape(@program[:product_name])}"
      lines << "Ставка от: <b>#{@program[:rate_min]}%</b> · Срок до <b>#{@program[:term_years_max] || 30}</b> лет"
      lines << ''
    end
    lines << "👤 <b>#{escape(@inquiry.name)}</b>"
    lines << "📞 #{escape(@inquiry.phone)}" if @inquiry.phone.present?
    lines << "✉️ #{escape(@inquiry.email)}" if @inquiry.email.present?

    if (meta = @inquiry.metadata).present?
      lines << ''
      if meta['property_price'].present?
        lines << "🏠 Цена объекта: #{fmt_rub(meta['property_price'])}"
      end
      lines << "📍 #{escape(meta['property_address'])}"  if meta['property_address'].present?
      lines << "💰 Первый взнос: #{fmt_rub(meta['down_payment'])}" if meta['down_payment'].present?
      lines << "📅 Срок: #{meta['loan_term']} лет" if meta['loan_term'].present?
      if meta['audit_report_number'].present?
        base = ENV['APP_URL'].presence || (defined?(AgencyInfo) ? AgencyInfo::WEBSITE_URL : 'https://victory62.org')
        lines << ""
        lines << %(🔗 <a href="#{base}/valuations/audit/#{meta['audit_token']}">Связанный инвест-аудит №#{meta['audit_report_number']}</a>)
      end
    end

    if @inquiry.message.present?
      lines << ''
      lines << "💬 #{escape(@inquiry.message.to_s.truncate(400))}"
    end

    lines.join("\n")
  end

  def fmt_rub(v)
    "#{v.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse} ₽"
  end

  def escape(s)
    s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end
end
