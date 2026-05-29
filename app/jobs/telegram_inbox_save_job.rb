# frozen_string_literal: true

# Async wrapper around Telegram::InboxSaver. Decouples photo/document
# downloads (which call out to api.telegram.org and may take several
# seconds for large files) from the webhook controller — Telegram itself
# only gives the webhook ~5 seconds before disconnecting and retrying.
#
# Marshal note: the raw `msg` Hash from Telegram contains only JSON
# primitives, so Sidekiq's strict JSON serialization (Rails 7 default)
# is happy without any transform.
class TelegramInboxSaveJob < ApplicationJob
  queue_as :default

  # Retry once on transient Telegram CDN hiccups, then give up — we don't
  # want a single huge document to clog the queue indefinitely.
  retry_on StandardError, wait: 5.seconds, attempts: 2

  def perform(msg)
    Telegram::InboxSaver.call(msg)
  end
end
