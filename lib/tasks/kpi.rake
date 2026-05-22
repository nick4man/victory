# frozen_string_literal: true

# Quick state snapshot for Phase A (premium-сегмент Рязани).
# Output stored at `.claude/sessions/kpi-cache.txt` and read by the
# SessionStart hook so all 3 Claude Code sessions see current state,
# not just the long-term strategic vector.
#
#   bundle exec rake kpi:phase_a > .claude/sessions/kpi-cache.txt
#
# Re-run manually (cron will come in Phase D AI-conveyor).
namespace :kpi do
  PREMIUM_PRICE_THRESHOLD = 15_000_000

  desc 'Phase A dashboard — premium listings, SEO coverage, inquiries pipeline'
  task phase_a: :environment do
    puts "Generated: #{Time.current.strftime('%d.%m.%y %H:%M')} MSK"
    puts ''

    puts '### Catalog'
    total       = Property.where(deal_type: :sale).count
    active      = Property.where(deal_type: :sale, status: :active).count
    premium_all = Property.where(deal_type: :sale).where('price >= ?', PREMIUM_PRICE_THRESHOLD).count
    premium_act = Property.where(deal_type: :sale, status: :active).where('price >= ?', PREMIUM_PRICE_THRESHOLD).count
    puts "  total sale listings:           #{total}"
    puts "  active listings:               #{active}"
    puts "  premium (>= #{(PREMIUM_PRICE_THRESHOLD / 1_000_000).to_i}M ₽), all:    #{premium_all}"
    puts "  premium, active:               #{premium_act}"

    puts ''
    puts '### SEO coverage'
    with_seo    = Property.where.not(seo_title: [nil, '']).count
    seo_pct     = total.positive? ? (with_seo * 100.0 / total).round(1) : 0
    premium_seo = Property.where(deal_type: :sale).where('price >= ?', PREMIUM_PRICE_THRESHOLD).where.not(seo_title: [nil, '']).count
    premium_seo_pct = premium_all.positive? ? (premium_seo * 100.0 / premium_all).round(1) : 0
    puts "  with seo_title (all):          #{with_seo}/#{total}  (#{seo_pct}%)"
    puts "  with seo_title (premium):      #{premium_seo}/#{premium_all}  (#{premium_seo_pct}%)"

    puts ''
    puts '### Inquiries (sales pipeline)'
    if defined?(Inquiry)
      # Phase 16 — фильтруем staff_test=true (Надеждины тесты, «Тест Клиент» и т.д.)
      # из real-client KPI. Tag показываем отдельной строкой для observability.
      real_scope = Inquiry.respond_to?(:where) && Inquiry.column_names.include?('staff_test') ?
                   Inquiry.where(staff_test: false) : Inquiry
      open_states = %w[new contacted in_progress scheduled]
      open_count  = real_scope.where(status: open_states).count
      stale_open  = real_scope.where(status: open_states).where('updated_at < ?', 7.days.ago).count
      week_new    = real_scope.where('created_at > ?', 7.days.ago).count
      completed_30 = real_scope.where(status: :completed).where('updated_at > ?', 30.days.ago).count
      puts "  open (new/contacted/in_progress/scheduled): #{open_count}"
      puts "  open + idle > 7 days:                       #{stale_open}"
      puts "  new last 7 days:                            #{week_new}"
      puts "  completed last 30 days:                     #{completed_30}"

      if Inquiry.column_names.include?('staff_test')
        staff_test_count = Inquiry.where(staff_test: true).count
        if staff_test_count.positive?
          breakdown = Inquiry.where(staff_test: true).group(:staff_test_matched_by).count
          puts "  [tagged staff_test, excluded above]:        #{staff_test_count} (#{breakdown.map { |k, v| "#{k}=#{v}" }.join(', ')})"
        end
      end
    else
      puts '  (Inquiry model not loaded — skip)'
    end

    puts ''
    puts '### Content'
    if defined?(Article)
      articles_total   = Article.respond_to?(:published) ? Article.published.count : Article.count
      articles_week    = Article.where('created_at > ?', 7.days.ago).count
      puts "  articles (published/total):    #{articles_total}"
      puts "  articles added last 7 days:    #{articles_week}"
    else
      puts '  (Article model not loaded — skip)'
    end

    puts ''
    puts '### Tech debt signals'
    no_images = Property.where(status: :active).where(images_count: 0).count
    no_price  = Property.where(status: :active).where(price: 0).count
    puts "  active listings without images:  #{no_images}"
    puts "  active listings price = 0:       #{no_price}"

    puts ''
    puts '### Strategic vector alignment (Phase A pillars)'

    # Phase 15 — Pillar 1 reality. Cabinet shipped в A7 + Phase 15 polish:
    # magic-link auth, profile/TG opt-in, password reset, properties, favorites,
    # consents+contracts PDF, inquiry list со status timeline. Считаем live:
    # сколько уникальных клиентов login'илось / TG-linked / имеют active inquiries.
    pillar1_label = begin
      clients_total = User.where(role: :client, active: true, deleted_at: nil).count
      clients_tg = User.where(role: :client, active: true, deleted_at: nil).where.not(tg_user_id: nil).count
      tg_pct = clients_total.positive? ? (clients_tg * 100.0 / clients_total).round : 0
      "client TG-linked #{clients_tg}/#{clients_total} (#{tg_pct}%)"
    rescue StandardError
      'n/a'
    end
    puts "  Pillar 1 (frictionless): cabinet shipped (A7+P15); #{pillar1_label}"

    cs_label = if defined?(CaseStudy)
                 total = CaseStudy.count
                 public_n = CaseStudy.respond_to?(:public_facing) ? CaseStudy.public_facing.count : total
                 "#{public_n}/#{total} (public/total)"
               else
                 'n/a (no CaseStudy model)'
               end
    puts "  Pillar 2 (deep expertise): case studies count = #{cs_label}"

    # Phase 15 — Pillar 3 reality. Считаем active properties с seo_title
    # (не total — inactive не индексируются).
    active_total = Property.where(status: :active).count
    active_with_seo = Property.where(status: :active).where.not(seo_title: [nil, '']).count
    active_pct = active_total.positive? ? (active_with_seo * 100.0 / active_total).round : 0
    puts "  Pillar 3 (AI×human): active LLM-meta #{active_with_seo}/#{active_total} (#{active_pct}%)"

    puts ''
    puts '### Yandex SEO'
    yandex_section
  rescue StandardError => e
    warn "[kpi:phase_a] ERROR: #{e.class}: #{e.message}"
    warn e.backtrace.first(5).join("\n")
    exit 1
  end

  # Yandex section — uses 12h cached snapshot (WebmasterSummaryService),
  # НЕ дёргает live API при каждом kpi run. Gracefully degrades если token
  # отсутствует или Yandex недоступен.
  def yandex_section
    unless defined?(Yandex::WebmasterSummaryService)
      puts '  (Yandex::WebmasterSummaryService not loaded — skip)'
      return
    end

    data = Yandex::WebmasterSummaryService.call
    summary = data[:summary] || {}
    sqi = summary['sqi']
    searchable = summary['searchable_pages_count']
    excluded = summary['excluded_pages_count']
    puts "  SQI (ИКС):                     #{sqi || '?'}"
    puts "  searchable pages:              #{searchable || '?'}"
    puts "  excluded pages:                #{excluded || '?'}"

    queries = data[:top_queries] || []
    if queries.any?
      total_shows = queries.sum { |q| q.dig('indicators', 'TOTAL_SHOWS').to_i }
      total_clicks = queries.sum { |q| q.dig('indicators', 'TOTAL_CLICKS').to_i }
      avg_ctr = total_shows.positive? ? (total_clicks.to_f / total_shows * 100).round(2) : 0
      puts "  top-#{queries.size} queries: shows=#{total_shows} clicks=#{total_clicks} CTR=#{avg_ctr}%"
    end

    ops_count = begin
                  defined?(Yandex::WebmasterOpportunitiesService) ? Yandex::WebmasterOpportunitiesService.call.size : '(service not loaded)'
                rescue StandardError
                  '?'
                end
    puts "  optimisation opportunities:    #{ops_count}"

    quota = data[:recrawl_quota]
    if quota
      puts "  recrawl quota:                 #{quota['quota_remainder']}/#{quota['daily_quota']} remaining"
    end

    diag = data[:diagnostics]
    if diag.is_a?(Hash) && diag[:active_count]
      puts "  active diagnostics issues:     #{diag[:active_count]}/#{diag[:total_keys]}"
    end
  rescue StandardError => e
    puts "  (Yandex section error: #{e.class}: #{e.message})"
  end
end
