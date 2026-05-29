# frozen_string_literal: true

# #413f Шаг 5 — каждое успешное cabinet activation пишет ActivationEvent.
# Lightweight log (только pings) для weekly analytics: сколько активаций
# через какой channel за период.
#
# Single source of truth: `ActivationEvent.log!(user:, channel:, ...)`
# вызывается ОДНАЖДЫ из processor/controller который выполнил linkage
# (LinkProcessor consume!, ActivationRequestProcessor handle_contact).
class ActivationEvent < ApplicationRecord
  belongs_to :user

  CHANNELS = %w[inbound cabinet_profile admin_panel bulk_pdf].freeze

  validates :channel,     inclusion: { in: CHANNELS }
  validates :happened_at, presence: true

  scope :recent,     ->(period = 7.days) { where('happened_at > ?', period.ago) }
  scope :by_channel, ->(channel) { where(channel: channel) }
  scope :in_range,   ->(range) { where(happened_at: range) }

  # @param user [User]
  # @param channel [String] one of CHANNELS
  # @param ip_address [String, nil] для audit-trail (опц)
  # @param metadata [Hash] free-form (e.g. tg_user_id, token_id, referrer)
  # @return [ActivationEvent] created record (на success)
  def self.log!(user:, channel:, ip_address: nil, metadata: {})
    create!(
      user:        user,
      channel:     channel,
      happened_at: Time.current,
      ip_address:  ip_address,
      metadata:    metadata
    )
  rescue StandardError => e
    # Не falter activation flow если log упал (e.g. DB hiccup).
    Rails.logger.error("[ActivationEvent.log!] #{e.class}: #{e.message.first(160)}")
    Sentry.capture_exception(e, extra: { user_id: user&.id, channel: channel }) if defined?(Sentry)
    nil
  end

  # Aggregation для weekly report.
  # @return [Hash] { channel => count, total: N }
  def self.channel_breakdown(range: 7.days.ago..Time.current)
    counts = in_range(range).group(:channel).count
    counts['total'] = counts.values.sum
    CHANNELS.each { |ch| counts[ch] ||= 0 }
    counts
  end
end
