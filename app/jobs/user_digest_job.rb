# frozen_string_literal: true

# User Digest Job
# Sends a weekly digest of new properties and market updates to subscribed users
class UserDigestJob < ApplicationJob
  queue_as :low_priority

  def perform
    Rails.logger.info 'Starting weekly user digest'

    users = User.active.confirmed.where(
      "notification_settings->>'newsletter' IS DISTINCT FROM 'false'"
    )

    Rails.logger.info "Sending digest to #{users.count} users"

    users.find_each do |user|
      UserMailer.weekly_digest(user).deliver_later
    rescue StandardError => e
      Rails.logger.error "Failed to queue digest for user ##{user.id}: #{e.message}"
    end

    Rails.logger.info 'Weekly user digest queued'
  end
end
