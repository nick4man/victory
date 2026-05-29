# frozen_string_literal: true

module Webhooks
  # Ingests news content from the chat-host cron pipeline. Called from
  # `urgent_trigger.py` and `weekly_digest_trigger.py` on the chat server
  # via curl + bearer token (see services/chat-host-cron/post_news_to_victory.sh).
  #
  # The audit-trail flow is:
  #   chat-cron creates urgent_*.txt + .meta.json → POST here →
  #   Article(external_source: chat_urgent) appears at /news within seconds.
  #
  # Idempotent on `external_id` (e.g. "urgent_20260511_141500"): repeated
  # POSTs with the same id update the existing article rather than create
  # a duplicate. Lets the cron retry safely on transient failures.
  class NewsIngestController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false
    before_action :authenticate_bearer!

    DEFAULT_CATEGORY = 'news'
    DEFAULT_SCHEMA = 'NewsArticle'

    def create
      attrs = normalize_payload(payload_params)
      return render(json: { error: 'invalid_payload', detail: attrs[:error] }, status: :unprocessable_entity) if attrs[:error]

      article = upsert_article(attrs)
      if article.persisted? && article.errors.empty?
        render json: {
          status: 'ok',
          action: @action,
          article_id: article.id,
          slug: article.slug,
          url: news_item_url(article.slug)
        }
      else
        render json: { error: 'validation_failed', detail: article.errors.full_messages }, status: :unprocessable_entity
      end
    end

    private

    def authenticate_bearer!
      configured = ENV['NEWS_INGEST_TOKEN'].to_s
      if configured.empty?
        Rails.logger.warn('[NewsIngest] NEWS_INGEST_TOKEN not set — refusing all requests')
        head :forbidden and return
      end
      header = request.headers['Authorization'].to_s
      provided = header.start_with?('Bearer ') ? header.split(' ', 2).last.to_s : header
      head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, configured)
    end

    def payload_params
      params.permit(
        :external_id, :external_source, :title, :body_md, :excerpt, :category,
        :schema_type, :published_at, :source_url, :image_url, :region,
        # Cross-link TG ↔ site (chat-host adds these; both optional —
        # missing values fall back to AgencyInfo defaults in Article).
        :telegram_channel_url, :telegram_channel_handle,
        hashtags: []
      )
    end

    def normalize_payload(p)
      return { error: 'title required' } if p[:title].to_s.strip.length < 10
      return { error: 'body_md required' } if p[:body_md].to_s.strip.length < 10

      category = Article::CATEGORIES.include?(p[:category].to_s) ? p[:category].to_s : DEFAULT_CATEGORY
      schema   = Article::SCHEMA_TYPES.include?(p[:schema_type].to_s) ? p[:schema_type].to_s : DEFAULT_SCHEMA
      source   = Article::EXTERNAL_SOURCES.include?(p[:external_source].to_s) ? p[:external_source].to_s : 'chat_urgent'
      published_at = safe_parse_time(p[:published_at]) || Time.current

      {
        external_id:     p[:external_id].presence,
        external_source: source,
        title:           p[:title].to_s.strip,
        body:            p[:body_md].to_s.strip,
        excerpt:         p[:excerpt].presence,
        category:        category,
        schema_type:     schema,
        region:          p[:region].presence,
        published_at:    published_at,
        metadata: {
          hashtags:                Array(p[:hashtags]).compact,
          source_url:              p[:source_url].presence,
          image_url:               p[:image_url].presence,
          telegram_channel_url:    p[:telegram_channel_url].presence,
          telegram_channel_handle: p[:telegram_channel_handle].presence,
          ingested_at:             Time.current.iso8601
        }.compact_blank
      }
    end

    def safe_parse_time(value)
      return nil if value.blank?
      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def upsert_article(attrs)
      existing = Article.find_by(external_id: attrs[:external_id]) if attrs[:external_id].present?
      if existing
        @action = 'updated'
        # Preserve admin-set hidden_at on updates — don't unhide on republish.
        existing.update(attrs.except(:external_id))
        existing
      else
        @action = 'created'
        Article.create(attrs)
      end
    end
  end
end
