# frozen_string_literal: true

# Первый подтверждённый образец спама (12.11.26): реклама «продвижения
# ботов» ботам. Записан вручную как blocked — локальные эвристики по
# умолчанию дают только suspect, здесь решение уже принял человек.
class SeedLocalSpamSample < ActiveRecord::Migration[8.1]
  def up
    SpamBlockedEntry.find_or_create_by!(entry_type: :domain, value: 'botmasterru.com') do |e|
      e.status = :blocked
      e.source = 'local'
      e.blocked_at = Time.current
    end

    # наш домен защищён от эвристик постоянно: manual-записи синк не стирает
    app_host = ENV.fetch('APP_DOMAIN', 'victory62.org').to_s.downcase
    [app_host, "www.#{app_host}"].uniq.each do |domain|
      SpamAllowlistEntry.unscoped.find_or_create_by!(domain: domain) { |e| e.manual = true }
    end
  end

  def down
    SpamBlockedEntry.find_by(entry_type: :domain, value: 'botmasterru.com')&.destroy

    app_host = ENV.fetch('APP_DOMAIN', 'victory62.org').to_s.downcase
    SpamAllowlistEntry.unscoped.where(domain: [app_host, "www.#{app_host}"].uniq, manual: true).destroy_all
  end
end
