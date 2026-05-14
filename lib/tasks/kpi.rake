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
      open_states = %w[new contacted in_progress scheduled]
      open_count  = Inquiry.where(status: open_states).count
      stale_open  = Inquiry.where(status: open_states).where('updated_at < ?', 7.days.ago).count
      week_new    = Inquiry.where('created_at > ?', 7.days.ago).count
      completed_30 = Inquiry.where(status: :completed).where('updated_at > ?', 30.days.ago).count
      puts "  open (new/contacted/in_progress/scheduled): #{open_count}"
      puts "  open + idle > 7 days:                       #{stale_open}"
      puts "  new last 7 days:                            #{week_new}"
      puts "  completed last 30 days:                     #{completed_30}"
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
    puts "  Pillar 1 (frictionless): personal cabinet — TODO"
    puts "  Pillar 2 (deep expertise): case studies count = #{defined?(Case) ? Case.count : 'n/a (no Case model yet)'}"
    puts "  Pillar 3 (AI×human): LLM-generated meta = #{with_seo} properties"
  rescue StandardError => e
    warn "[kpi:phase_a] ERROR: #{e.class}: #{e.message}"
    warn e.backtrace.first(5).join("\n")
    exit 1
  end
end
