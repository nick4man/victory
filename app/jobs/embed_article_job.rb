# frozen_string_literal: true

require 'digest'

# Generates / refreshes the gemini-embedding-001 vector for an Article.
# Skips work if the template text has not changed (content_hash match).
#
# Triggers:
#   * Article after_commit when title/body/category/metadata changed
#   * Webhook::NewsIngestController upserts → after_commit fires
#   * `rake embeddings:articles` for one-shot bulk
class EmbedArticleJob < ApplicationJob
  queue_as :low_priority

  retry_on Embedding::GoogleClient::Error, wait: :polynomially_longer, attempts: 5

  def perform(article_id)
    article = Article.find_by(id: article_id)
    return unless article

    text = Embedding::ArticleTextTemplate.build(article)
    return if text.blank?

    hash = Digest::SHA256.hexdigest(text)

    record = ArticleEmbedding.find_or_initialize_by(article_id: article.id)
    if record.persisted? && record.content_hash == hash
      Rails.logger.debug("[EmbedArticleJob] article=#{article.id} unchanged, skip")
      return
    end

    vector = Embedding::GoogleClient.new.embed(text)

    record.update!(
      content_hash: hash,
      content_text: text,
      embedding:    vector,
      embedded_at:  Time.current
    )
    Rails.logger.info("[EmbedArticleJob] embedded article=#{article.id} dim=#{vector.size}")
  end
end
