# frozen_string_literal: true

# Yandex.Webmaster API v4 — еженедельный snapshot SEO-метрик.
#
# Использование:
#   rake yandex:webmaster:summary             # markdown в STDOUT
#   rake 'yandex:webmaster:summary[refresh]'  # bust cache, fresh pull
#   rake yandex:webmaster:summary:tg          # отправить в staff TG-чат
#
# Cron: 0 9 * * 1 (понедельник 09:00 МСК) — еженедельный пульс рядом с
# weekly_digest. Триггерить можно из victory-host или chat-host (через
# /webhooks/news_ingest или прямо bin/rails runner).
namespace :yandex do
  namespace :webmaster do
    desc 'Pull Я.Вебмастер snapshot (SQI, sitemap, top queries) — markdown в STDOUT'
    task :summary, %i[refresh] => :environment do |_, args|
      force = args[:refresh].to_s == 'refresh'
      data = Yandex::WebmasterSummaryService.call(force_refresh: force)
      puts WebmasterMarkdown.render(data)
    rescue Yandex::WebmasterSummaryService::ConfigError => e
      warn "[yandex:webmaster:summary] CONFIG: #{e.message}"
      warn 'Ожидаемые env vars: YANDEX_WEBMASTER_TOKEN, YANDEX_WEBMASTER_USER_ID'
      exit 1
    end

    desc 'Pull + отправить в TG staff-чат'
    task tg: :environment do
      data = Yandex::WebmasterSummaryService.call(force_refresh: true)
      markdown = WebmasterMarkdown.render(data)
      chat_id = ENV['TELEGRAM_STAFF_CHAT_ID'].presence
      if chat_id.blank?
        warn '[yandex:webmaster:summary:tg] TELEGRAM_STAFF_CHAT_ID не задан — печатаю в STDOUT.'
        puts markdown
        next
      end
      Telegram::Client.new.send_message(chat_id: chat_id, text: markdown, parse_mode: 'Markdown')
      puts '[yandex:webmaster:summary:tg] отправлено в staff-чат.'
    end
  end
end

# Inline формирователь markdown — встроен в rake чтобы не плодить app/services
# entries для одноразового использования. Если когда-нибудь понадобится
# вне rake (например, admin dashboard) — вынести в app/services/yandex/.
module WebmasterMarkdown
  module_function

  def render(data)
    return '_(нет данных от Я.Вебмастера)_' if data.blank?

    parts = [
      header(data),
      sqi_section(data[:summary], data[:sqi_history]),
      sitemap_section(data[:sitemaps]),
      queries_section(data[:top_queries])
    ]
    parts.compact.join("\n\n")
  end

  def header(data)
    host = data[:host_id].to_s.tr(':', '').sub(/^https/, 'https://').sub('443', '')
    "*Я.Вебмастер — снимок #{data[:fetched_at]&.strftime('%d.%m.%y %H:%M')}*\nХост: `#{host}`"
  end

  def sqi_section(summary, sqi_history)
    return nil unless summary

    sqi = summary['sqi']
    searchable = summary['searchable_pages_count']
    excluded = summary['excluded_pages_count']
    trend = sqi_trend_arrow(sqi_history)

    [
      '*SQI (ИКС)*',
      "  Текущий: *#{sqi || '?'}* #{trend}".rstrip,
      "  Страниц в поиске: *#{searchable || '?'}*",
      "  Исключено: *#{excluded || '?'}*"
    ].join("\n")
  end

  def sqi_trend_arrow(points)
    return '' if points.blank? || points.size < 2

    sorted = points.sort_by { |p| p['date'].to_s }
    first = sorted.first['value'].to_i
    last  = sorted.last['value'].to_i
    delta = last - first
    case delta
    when 0  then "_(стабильно за #{points.size}д)_"
    when 1.. then "_(↑ +#{delta} за #{points.size}д)_"
    else "_(↓ #{delta} за #{points.size}д)_"
    end
  end

  def sitemap_section(sitemaps)
    return nil if sitemaps.blank?

    lines = ['*Sitemap*']
    sitemaps.each do |s|
      last_access = parse_dt(s['last_access_date'])&.strftime('%d.%m.%y %H:%M') || '?'
      lines << "  `#{File.basename(s['sitemap_url'])}` — last access #{last_access}, " \
               "errors=#{s['errors_count'] || 0}, urls=#{s['urls_count'] || 0}"
    end
    lines.join("\n")
  end

  def queries_section(queries)
    return '_(показов за период нет)_' if queries.blank?

    lines = ['*Top запросы (по показам)*']
    queries.first(20).each_with_index do |q, i|
      ind = q['indicators'] || {}
      shows = ind['TOTAL_SHOWS'].to_i
      clicks = ind['TOTAL_CLICKS'].to_i
      avg_pos = ind['AVG_SHOW_POSITION']
      pos = avg_pos ? format('%.1f', avg_pos) : '—'
      text = q['query_text'].to_s.truncate(70)
      lines << "  #{format('%2d', i + 1)}. показов=#{shows} клик=#{clicks} pos=#{pos} — #{text}"
    end
    lines.join("\n")
  end

  def parse_dt(value)
    return nil if value.blank?

    Time.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
