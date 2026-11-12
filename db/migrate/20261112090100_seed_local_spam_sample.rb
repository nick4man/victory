# frozen_string_literal: true

# Первый подтверждённый образец спама (12.11.2026): реклама «продвижения
# ботов» ботам. Записан вручную как blocked — локальные эвристики по
# умолчанию дают только suspect, здесь решение уже принял человек.
class SeedLocalSpamSample < ActiveRecord::Migration[8.1]
  def up
    SpamBlockedEntry.find_or_create_by!(entry_type: :domain, value: 'botmasterru.com') do |e|
      e.status = :blocked
      e.source = 'local'
      e.blocked_at = Time.current
    end
  end

  def down
    SpamBlockedEntry.find_by(entry_type: :domain, value: 'botmasterru.com')&.destroy
  end
end
