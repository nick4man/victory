# frozen_string_literal: true

# Use this file to easily define all of your cron jobs.
# Learn more: http://github.com/javan/whenever
#
# Example:
#
# set :output, "/path/to/my/cron_log.log"
#
# every 2.hours do
#   command "/usr/bin/some_great_command"
#   runner "MyModel.some_method"
#   rake "some:great:rake:task"
# end
#
# every 4.days do
#   runner "AnotherModel.prune_old_records"
# end

# Set environment
set :environment, ENV['RAILS_ENV'] || 'development'
set :output, { error: 'log/cron_error.log', standard: 'log/cron.log' }

# Send viewing reminders every hour
every 1.hour do
  runner 'SendViewingRemindersJob.perform_later'
end

# Refresh Topnlab counts cache (processed_requests metric on landing).
# Topnlab API throttles to 1 req/6s — full sweep ≈ 8 min, must NOT run inline.
every 1.hour do
  runner 'RefreshTopnlabStatsJob.perform_later'
end

# Update property statistics daily at 3 AM
every 1.day, at: '3:00 am' do
  runner 'UpdatePropertyStatisticsJob.perform_later'
end

# Send property valuation follow-ups daily at 10 AM
every 1.day, at: '10:00 am' do
  runner <<-RUBY
    PropertyValuation.where(
      'created_at < ? AND created_at > ? AND follow_up_email_sent = ?',
      3.days.ago,
      4.days.ago,
      false
    ).find_each do |valuation|
      PropertyValuationFollowUpJob.perform_later(valuation.id)
    end
  RUBY
end

# Clean up old sessions weekly
every 1.week, at: '2:00 am' do
  rake 'db:sessions:trim'
end

# Generate sitemap daily
every 1.day, at: '4:00 am' do
  rake 'sitemap:refresh'
end

# Backup database daily
every 1.day, at: '1:00 am' do
  command 'cd /home/q/site/project/viktory_realty && bin/backup_database.sh'
end

# Clear expired cache entries
every 6.hours do
  rake 'cache:clear_expired'
end

# Send digest emails to users (weekly)
every :sunday, at: '9:00 am' do
  runner 'UserDigestJob.perform_later'
end

# Check for expired property listings
every 1.day, at: '8:00 am' do
  runner <<-RUBY
    Property.where(
      'expires_at < ? AND status = ?',
      Date.current,
      'active'
    ).update_all(status: 'expired')
  RUBY
end

# Update market analytics
every 1.day, at: '5:00 am' do
  runner 'MarketAnalyticsUpdateJob.perform_later'
end

# Phase 3 — TG SLA watchdog: лиды без first_contact > 30 мин с момента assign.
# Каждые 5 мин. Пинг в #ДИСПЕТЧЕРСКОЙ + DM назначенному (с учётом quiet hours).
every 5.minutes do
  runner 'Telegram::WorkBot::Sla::WatchdogJob.perform_later'
end

# Phase 3 — TG SLA tasks watchdog: задачи с due_at < now. Каждые 5 мин.
# Дедуп per-task через last_pinged_at (max раз в 6 часов на одну задачу).
every 5.minutes do
  runner 'Telegram::WorkBot::Sla::TasksWatchdogJob.perform_later'
end

# Phase 2 Hotfix — TG polling fallback зарегистрирован в config/sidekiq_cron.yml
# (this project uses sidekiq-cron, not whenever). См. там job `tg_polling`.

# Phase 3 — еженедельный refresh Topnlab stages mapping (на случай если admin
# переименовал стадии в CRM). Воскресенье 03:00 MSK.
every :sunday, at: '3:00 am' do
  rake 'topnlab:stages:refresh'
end

# ============================================
# SEO / Yandex.Webmaster — data-driven SEO cycle
# ============================================
# Deployment note: schedule.rb — source of truth, но `whenever --update-crontab`
# не запускался регулярно. На host'е был manual crontab entry для yandex:tg —
# здесь зафиксирована canonical версия + новые entries для new tooling.
# Deploy: `bundle exec whenever --update-crontab` после review.

# Weekly Yandex.Webmaster summary (SQI + queries + sitemap + diagnostics) →
# admin DM (или staff fallback). Понедельник 06:00 MSK — еженедельный SEO пульс.
every :monday, at: '6:00 am' do
  rake 'yandex:webmaster:tg'
end

# Weekly opportunity detection — queries c low CTR / mid position / real
# impressions → optimisation targets. Wednesday 09:00 MSK (середина недели,
# время на действие до конца недели). Output в log файл — TG-доставку добавим
# когда нужен push-уведомление.
every :wednesday, at: '9:00 am' do
  rake 'yandex:webmaster:opportunities'
end

# Daily Yandex diagnostics — кратко в log; если active > 1 — alert через TG
# выносим в follow-up subplan (нужен yandex:webmaster:diagnostics:tg-on-alert task).
every 1.day, at: '7:00 am' do
  rake 'yandex:webmaster:diagnostics'
end

# ============================================
# KPI cache refresh — для SessionStart hook
# ============================================
# KPI dashboard в SessionStart hook читает .claude/sessions/kpi-cache.txt и
# warning'и stale если файл старше 24h. Refresh каждые 6 часов чтобы число
# в hook было свежим без burning live API calls.
every 6.hours do
  command 'cd /home/q/victory && /usr/bin/docker compose exec -T web bundle exec rake kpi:phase_a > /home/q/victory/.claude/sessions/kpi-cache.txt 2>> /home/q/victory/log/kpi-cron.log'
end

# ============================================
# Inter-session hygiene
# ============================================
# Stale lock cleanup — empty или > 2h lock files в tmp/claude-locks/.
# Воскресенье 00:00 — quiet hour, ничего активного.
every :sunday, at: '0:00 am' do
  command 'cd /home/q/victory && /home/q/victory/bin/lock-clean --force >> /home/q/victory/log/lock-clean-cron.log 2>&1'
end
