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

    desc 'Pull + отправить в TG (recipient = TELEGRAM_ADMIN_DM_CHAT_ID или TELEGRAM_STAFF_CHAT_ID)'
    task tg: :environment do
      data = Yandex::WebmasterSummaryService.call(force_refresh: true)
      markdown = WebmasterMarkdown.render(data)

      # Precedence: TELEGRAM_ADMIN_DM_CHAT_ID > TELEGRAM_STAFF_CHAT_ID.
      # Admin DM приватнее — owner получает SEO-метрики персонально без шума
      # в staff-чате. STAFF-чат — fallback если DM env не задан.
      chat_id = ENV['TELEGRAM_ADMIN_DM_CHAT_ID'].presence || ENV['TELEGRAM_STAFF_CHAT_ID'].presence
      if chat_id.blank?
        warn '[yandex:webmaster:summary:tg] ни TELEGRAM_ADMIN_DM_CHAT_ID, ни TELEGRAM_STAFF_CHAT_ID не задан — печатаю в STDOUT.'
        puts markdown
        next
      end

      Telegram::Client.new.send_message(markdown, chat_id: chat_id, parse_mode: 'Markdown')
      target = ENV['TELEGRAM_ADMIN_DM_CHAT_ID'].present? ? 'admin DM' : 'staff-чат'
      puts "[yandex:webmaster:summary:tg] отправлено в #{target} (chat_id=#{chat_id})."
    end

    desc 'POST single URL в Я.Recrawl queue. Usage: rake "yandex:webmaster:recrawl[https://victory62.org/]"'
    task :recrawl, %i[url] => :environment do |_, args|
      url = args[:url].to_s
      if url.blank?
        warn 'usage: rake "yandex:webmaster:recrawl[https://victory62.org/some-url]"'
        exit 1
      end
      result = Yandex::WebmasterRecrawlService.queue(url)
      if result.ok?
        puts "OK queued #{url}"
        puts "  task_id=#{result.task_id}"
        puts "  remaining_quota=#{result.remaining_quota}/150"
      else
        warn "FAIL #{url} — #{result.error}"
        exit 2
      end
    end

    namespace :recrawl do
      desc 'POST критические URLs (homepage + sitemap-index + top landings) одним вызовом'
      task critical: :environment do
        host = (ENV['CANONICAL_HOST'].presence || 'https://victory62.org').sub(%r{/$}, '')
        urls = [
          "#{host}/",
          "#{host}/sitemap.xml",
          "#{host}/sitemap-news.xml",
          "#{host}/kupit/kvartira",
          "#{host}/kupit/kvartira/premium",
          "#{host}/property_valuations/new",
          "#{host}/about",
          "#{host}/reviews",
          "#{host}/blog",
          "#{host}/cases"
        ]

        quota_before = Yandex::WebmasterRecrawlService.quota
        if quota_before && quota_before[:remaining] < urls.size
          warn "[recrawl:critical] осталось #{quota_before[:remaining]} URLs в квоте, нужно #{urls.size}. Skip."
          next
        end

        ok = 0
        fail_count = 0
        urls.each do |u|
          result = Yandex::WebmasterRecrawlService.queue(u)
          if result.ok?
            ok += 1
            puts "  ✓ #{u} task=#{result.task_id}"
          else
            fail_count += 1
            warn "  ✗ #{u} — #{result.error}"
          end
        end

        quota_after = Yandex::WebmasterRecrawlService.quota
        puts ""
        puts "Submitted: #{ok}/#{urls.size} (failed: #{fail_count})"
        puts "Quota: #{quota_before&.dig(:remaining) || '?'} → #{quota_after&.dig(:remaining) || '?'} / #{quota_after&.dig(:daily) || 150}"
      end

      desc 'Текущий quota Я.Recrawl (use/daily/remaining/burn%)'
      task quota: :environment do
        q = Yandex::WebmasterRecrawlService.quota
        if q.nil?
          warn 'Quota недоступен (API error или config missing)'
          exit 1
        end
        puts "  daily quota:      #{q[:daily]}"
        puts "  used today:       #{q[:used]} (#{(q[:used_fraction] * 100).round}%)"
        puts "  remaining:        #{q[:remaining]}"
      end
    end

    desc 'SEO opportunities — queries с потенциалом (low CTR + middle position + real impressions)'
    task opportunities: :environment do
      ops = Yandex::WebmasterOpportunitiesService.call
      if ops.empty?
        puts '_(нет opportunities выше порога — site свежий OR queries уже well-optimised)_'
        next
      end
      puts "*SEO opportunities (#{ops.size} queries)*"
      puts ''
      puts format('%-50s | %5s | %5s | %6s | %4s | %s', 'query', 'imp', 'clicks', 'CTR', 'pos', 'missed')
      puts '-' * 100
      ops.first(20).each do |o|
        puts format('%-50s | %5d | %5d | %5.2f%% | %4.1f | %d',
                    o[:query].to_s.truncate(50),
                    o[:impressions], o[:clicks],
                    o[:ctr] * 100, o[:avg_position],
                    o[:missed_clicks_estimate])
      end
      puts ''
      total_missed = ops.sum { |o| o[:missed_clicks_estimate] }
      puts "Total missed-clicks estimate: #{total_missed} (если все улучшить до target CTR)"
    end

    desc 'Diagnostics — active problems detected by Я.Webmaster'
    task diagnostics: :environment do
      data = Yandex::WebmasterSummaryService.call(force_refresh: false)
      d = data[:diagnostics]
      if d.blank? || d[:active_count].zero?
        puts '_(нет активных проблем — Я.Webmaster видит сайт чистым)_'
        next
      end
      puts "*Diagnostics — #{d[:active_count]}/#{d[:total_keys]} активных проблем*"
      d[:active].each do |p|
        sev_marker = case p[:severity]
                     when 'FATAL' then '🛑'
                     when 'ERROR' then '⚠️ '
                     when 'POSSIBLE_PROBLEM' then '⚠ '
                     when 'RECOMMENDATION' then 'ℹ️ '
                     else '•'
                     end
        puts "  #{sev_marker} #{p[:key]} (#{p[:severity]}) — updated #{p[:updated]}"
      end
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
      diagnostics_section(data[:diagnostics]),
      crawl_health_section(data[:indexing_history]),
      recrawl_quota_section(data[:recrawl_quota]),
      sitemap_section(data[:sitemaps]),
      queries_section(data[:top_queries]),
      popular_pages_section(data[:popular_pages])
    ]
    parts.compact.join("\n\n")
  end

  # Y. Webmaster диагностика — Я.сам говорит про активные проблемы. На
  # 18.05 у нас FAVICON_PROBLEM (RECOMMENDATION) — Я. ещё не подхватил
  # обновлённый favicon. Endpoint полезен для weekly health-check —
  # автоматически surfaces всё что Я. видит как issue. %>
  def diagnostics_section(diag)
    return nil if diag.blank? || diag[:active_count].to_i.zero?

    lines = ["*Diagnostics — #{diag[:active_count]} активных проблем(а)*"]
    Array(diag[:active]).first(6).each do |p|
      marker = case p[:severity]
               when 'FATAL' then '🛑'
               when 'ERROR' then '⚠️'
               when 'POSSIBLE_PROBLEM' then '⚠'
               when 'RECOMMENDATION' then 'ℹ️'
               else '•'
               end
      updated = parse_dt(p[:updated])&.strftime('%d.%m.%y') || '?'
      lines << "  #{marker} `#{p[:key]}` (#{p[:severity]}) — updated #{updated}"
    end
    lines.join("\n")
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

  # Crawl health — суммируем HTTP_2XX/4XX/5XX за last 14 дней. 4XX/5XX
  # spike — сильный signal для investigate. Y.API возвращает hash вида
  # `{indicators: {HTTP_2XX: [{date, value}, ...], HTTP_4XX: [...]}}`.
  # Если service вернул flat array (другой shape) — пытаемся достать
  # из data["indicators"]. NA если данных нет.
  def crawl_health_section(history)
    return nil if history.blank?

    indicators = history.is_a?(Hash) ? (history['indicators'] || history) : { 'HTTP_2XX' => history }
    sums = {
      '2XX' => sum_indicator(indicators, %w[HTTP_2XX]),
      '3XX' => sum_indicator(indicators, %w[HTTP_3XX]),
      '4XX' => sum_indicator(indicators, %w[HTTP_4XX]),
      '5XX' => sum_indicator(indicators, %w[HTTP_5XX])
    }
    return nil if sums.values.sum.zero?

    warn_flag = sums['4XX'].positive? || sums['5XX'].positive? ? '  ⚠️ Есть error-responses — проверить в Я.Вебмастер «Страницы в поиске → Ошибки»' : nil
    [
      '*Crawl health (14d)*',
      "  HTTP 2XX: *#{sums['2XX']}*  3XX: #{sums['3XX']}  4XX: *#{sums['4XX']}*  5XX: *#{sums['5XX']}*",
      warn_flag
    ].compact.join("\n")
  end

  def sum_indicator(indicators, keys)
    keys.sum do |k|
      Array(indicators[k]).sum { |point| point['value'].to_i }
    end
  end

  def recrawl_quota_section(quota)
    return nil if quota.blank?

    daily = quota['daily_quota'].to_i
    remainder = (quota['quota_remainder'] || quota['quota_remaining_daily']).to_i
    used = daily - remainder
    pct = daily.positive? ? (used.to_f / daily * 100).round : 0

    [
      '*Recrawl quota*',
      "  использовано: *#{used}/#{daily}* (#{pct}%) · осталось *#{remainder}* до 00:00 МСК"
    ].join("\n")
  end

  def popular_pages_section(pages)
    return nil if pages.blank?

    lines = ['*Top страниц (по показам)*']
    pages.first(10).each_with_index do |p, i|
      ind = p['indicators'] || {}
      shows = ind['TOTAL_SHOWS'].to_i
      clicks = ind['TOTAL_CLICKS'].to_i
      url = p['url'].to_s.sub(%r{^https?://victory62\.org}, '').presence || '/'
      lines << "  #{format('%2d', i + 1)}. показов=#{shows} клик=#{clicks} — `#{url.truncate(60)}`"
    end
    lines.join("\n")
  end
end
