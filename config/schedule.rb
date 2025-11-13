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

