# frozen_string_literal: true

# MLS / YRL launch orchestration — Phase 0, 1, 2 из plan'a
# `.claude/plans/merry-honking-kay.md`.
#
# Запуски:
#   docker exec victory-web-1 bin/rake yrl:baseline
#   docker exec victory-web-1 bin/rake yrl:launch:phase1
#   docker exec victory-web-1 bin/rake yrl:launch:phase1_dry      # без apply
#   docker exec victory-web-1 bin/rake yrl:launch:phase2_recrawl  # top external listings (Phase 2 step 6)
#
# Все task'и — idempotent + quota-disciplined.
namespace :yrl do
  TODAY = Date.current.strftime('%Y-%m-%d')

  desc 'Phase 0 — snapshot Yandex.Webmaster baseline (SQI + opportunities + quota)'
  task baseline: :environment do
    artifacts_dir = Rails.root.join('tmp')

    puts "=== YRL Phase 0 — Yandex baseline snapshot (#{TODAY}) ===\n\n"

    # 1. Summary (SQI, top queries, sitemap status)
    summary_path = artifacts_dir.join("yandex_baseline_#{TODAY}.json")
    print 'Pulling WebmasterSummaryService.call(force_refresh: true)… '
    summary = Yandex::WebmasterSummaryService.call(force_refresh: true)
    File.write(summary_path, JSON.pretty_generate(summary))
    sqi = summary.dig(:summary, 'sqi') || summary.dig(:summary, :sqi) || summary.dig('summary', 'sqi')
    puts "OK (SQI: #{sqi.inspect}, file: #{summary_path.basename})"

    # 2. Opportunities (mid-position high-impressions queries)
    opps_path = artifacts_dir.join("yandex_opportunities_#{TODAY}.json")
    print 'Pulling WebmasterOpportunitiesService.call(min_impressions: 50)… '
    opps = Yandex::WebmasterOpportunitiesService.call(min_impressions: 50)
    File.write(opps_path, JSON.pretty_generate(opps))
    puts "OK (#{Array(opps).size} opportunities, file: #{opps_path.basename})"

    # 3. Recrawl quota check
    print 'Checking WebmasterRecrawlService.quota… '
    quota = Yandex::WebmasterRecrawlService.quota
    remainder = quota.is_a?(Hash) ? (quota[:remaining] || quota[:quota_remainder]) : nil
    daily    = quota.is_a?(Hash) ? (quota[:daily]     || quota[:daily_quota])     : nil
    puts "remaining=#{remainder.inspect} / daily=#{daily.inspect}"
    if remainder.to_i < 100
      warn "\n[WARN] remaining=#{remainder} — Phase 1 нужно 21+, Phase 2 ещё 20. Перенести на завтра (resets полночью МСК)."
    end

    puts "\n✓ Baseline saved. Diff'и через 7 дней после Phase 1+2:"
    puts "    diff <(jq -S . #{summary_path.basename}) <(jq -S . yandex_baseline_<future-date>.json)"
  rescue Yandex::WebmasterSummaryService::ConfigError => e
    warn "[yrl:baseline] CONFIG ERROR: #{e.message}"
    warn 'Required env: YANDEX_WEBMASTER_TOKEN, YANDEX_WEBMASTER_USER_ID'
    exit 1
  end

  namespace :launch do
    desc 'Phase 1 — dry-run: count properties that would flip in_mls=true'
    task phase1_dry: :environment do
      candidates = Property.unscoped
                           .on_site
                           .where(external_source: 'topnlab', deal_state: 'ad')
                           .where(in_mls: [false, nil])
      puts "[Phase 1 DRY] would update_all(in_mls: true) для #{candidates.count} property(ies)"
      candidates.limit(5).each { |p| puts "  id=#{p.id} slug=#{p.slug} title=#{p.title.truncate(50)}" }
    end

    desc 'Phase 1 — backfill in_mls=true + ping Webmaster recrawl для newly published URLs'
    task phase1: :environment do
      puts "=== YRL Phase 1 — in_mls backfill + recrawl ping (#{Time.current}) ===\n\n"

      # Step 1: backfill in_mls (idempotent — может быть 0 candidates если
      # mapper уже set'нул на previous import).
      candidates = Property.unscoped
                           .on_site
                           .where(external_source: 'topnlab', deal_state: 'ad')
                           .where(in_mls: [false, nil])
      affected_ids = candidates.pluck(:id)
      n = candidates.update_all(in_mls: true)
      puts "✓ Backfilled in_mls=true для #{n} property(ies). IDs: #{affected_ids.inspect}"

      # Step 2: feed sanity check (in_advertising count)
      adv_count = Property.in_advertising.count
      puts "✓ Property.in_advertising.count = #{adv_count}"

      # Step 3: recrawl pings.
      # При initial launch — backfill вернул 0 потому что mapper уже всё
      # выставил. Но property pages всё равно нуждаются в recrawl (мы
      # недавно фиксили rooms/title для multi-room квартир). Ping the
      # top-20 in_advertising regardless of recent update.
      # Respect daily quota: min_remaining=50.
      base = ENV.fetch('APP_URL', 'https://victory62.org')
      target_ids = affected_ids.presence || Property.in_advertising.order(updated_at: :desc).limit(20).pluck(:id)
      to_ping = Property.unscoped.where(id: target_ids).limit(20)
      puts "\nPinging Yandex recrawl для #{to_ping.size} URL'ов (min_remaining: 50)…"

      success = failed = 0
      to_ping.each do |p|
        url = "#{base}/properties/#{p.slug}"
        begin
          result = Yandex::WebmasterRecrawlService.queue(url, min_remaining: 50)
          if result.ok?
            success += 1
            puts "  ✓ #{url} → queued (remainder=#{result.remaining_quota})"
          else
            failed += 1
            puts "  ✗ #{url} → #{result.error}"
          end
        rescue Yandex::WebmasterRecrawlService::QuotaExceeded => e
          puts "  ⚠ quota threshold hit — stopping. #{e.message}"
          break
        rescue StandardError => e
          failed += 1
          puts "  ✗ #{url} → #{e.class}: #{e.message.truncate(120)}"
        end
        sleep 0.3
      end

      # Step 4: feed URL ping (Yandex may or may not crawl XML; harmless)
      begin
        feed_url = "#{base}/feeds/yrl.xml"
        Yandex::WebmasterRecrawlService.queue(feed_url, min_remaining: 30)
        puts "✓ Pinged feed URL: #{feed_url}"
      rescue Yandex::WebmasterRecrawlService::QuotaExceeded
        puts "(feed ping skipped — quota threshold)"
      rescue StandardError => e
        puts "(feed ping failed: #{e.class}: #{e.message.truncate(120)} — non-fatal)"
      end

      puts "\n=== Phase 1 DONE: backfill=#{n}, pinged=#{success}, failed=#{failed} ==="
    end

    desc 'Phase 2 — ping recrawl для top-20 high-value ExternalListing URLs'
    task phase2_recrawl: :environment do
      puts "=== YRL Phase 2 — recrawl pings for top external listings ===\n\n"

      base = ENV.fetch('APP_URL', 'https://victory62.org')
      premium_districts = %w[Канищево Центр Солотча]

      # ExternalListing scopes: .active (closed_at IS NULL), .priced (price > 0),
      # .recent (fetched_at > N.days.ago). Combine для quality filter.
      base_scope = ExternalListing.active.priced
      hi_value = base_scope.where('price >= ?', 10_000_000)
                           .or(base_scope.where(district: premium_districts))
                           .order(price: :desc)
                           .limit(20)

      if hi_value.empty?
        puts '(no high-value ExternalListing yet — populate ENV["YRL_FEED_URLS"] and let cron sync)'
        next
      end

      puts "Pinging Yandex recrawl для #{hi_value.size} external listing URL'ов (min_remaining: 30)…"
      success = failed = 0
      hi_value.each do |el|
        url = "#{base}/external-listings/#{el.id}"
        begin
          result = Yandex::WebmasterRecrawlService.queue(url, min_remaining: 30)
          if result.ok?
            success += 1
            puts "  ✓ #{url} → queued (remainder=#{result.remaining_quota})"
          else
            failed += 1
            puts "  ✗ #{url} → #{result.error}"
          end
        rescue Yandex::WebmasterRecrawlService::QuotaExceeded => e
          puts "  ⚠ quota threshold hit — stopping. #{e.message}"
          break
        rescue StandardError => e
          failed += 1
          puts "  ✗ #{url} → #{e.class}: #{e.message.truncate(120)}"
        end
        sleep 0.3
      end

      puts "\n=== Phase 2 recrawl DONE: pinged=#{success}, failed=#{failed} ==="
    end
  end
end
