# frozen_string_literal: true

# Pings Oksana when a new pending Review lands. Re-uses the existing
# Telegram::Client (TELEGRAM_BOT_TOKEN) and prefers
# TELEGRAM_REVIEWS_CHAT_ID, falling back to TELEGRAM_STAFF_CHAT_ID.
# If no Telegram is configured, silently no-ops — the review still sits
# in /admin/reviews waiting for moderation.
class ReviewModerationNotifier
  def self.notify(review)
    new(review).call
  rescue StandardError => e
    Rails.logger.warn("[ReviewModerationNotifier] failed: #{e.class} #{e.message}")
    false
  end

  def initialize(review)
    @review = review
  end

  def call
    chat_id = ENV['TELEGRAM_REVIEWS_CHAT_ID'].presence || ENV['TELEGRAM_STAFF_CHAT_ID'].presence
    return false if chat_id.blank?
    return false if ENV['TELEGRAM_BOT_TOKEN'].blank?

    Telegram::Client.new.send_message(format_message, chat_id: chat_id, parse_mode: 'HTML')
    true
  end

  private

  def format_message
    lines = []
    lines << "⭐ <b>Новый отзыв на модерации</b>"
    lines << ''
    lines << "👤 #{escape(@review.display_author)}#{contact_line}"
    lines << "🌟 Оценка: #{@review.rating}/5 (#{@review.stars})"
    if @review.title.present?
      lines << "📌 <b>#{escape(@review.title)}</b>"
    end
    lines << ''
    lines << escape(@review.body.to_s.truncate(500))

    if @review.property.present?
      lines << ''
      lines << "🏠 Объект: #{escape(@review.property.title.to_s.truncate(80))}"
    end

    lines << ''
    lines << "🛠 Канал: #{submitted_via_label}"
    if @review.ip_address.present?
      lines << "🔗 IP: #{escape(@review.ip_address)}"
    end

    if (token = ENV['ADMIN_TOKEN']).present?
      base = ENV['APP_URL'].presence || AgencyInfo::WEBSITE_URL
      lines << ''
      lines << %(▶️ <a href="#{base}/admin/reviews/#{@review.id}?token=#{CGI.escape(token)}">Открыть в админке</a>)
    end

    lines.join("\n")
  end

  def contact_line
    parts = []
    parts << @review.author_email if @review.author_email.present?
    parts << @review.author_phone if @review.author_phone.present?
    parts.empty? ? '' : " · #{escape(parts.join(' · '))}"
  end

  def submitted_via_label
    case @review.submitted_via
    when 'web_form' then 'форма на сайте'
    when 'chat_bot' then 'чат-бот'
    when 'admin'    then 'админка'
    when 'import'   then 'импорт'
    else                 'неизвестно'
    end
  end

  def escape(text)
    text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
  end
end
