# frozen_string_literal: true

# /news — public news feed for АН Виктори. Powered by the same Article
# model used by /blog, but with `category` filtering (news + market by
# default) and a macro-snapshot sidebar (current CB-RF rates).
#
# Content arrives via two channels:
#   1. Webhooks::NewsIngestController — chat-host cron pushes (urgent + digest)
#   2. Admin::ArticlesController — manual entries by staff
class NewsController < ApplicationController
  FEED_CATEGORIES = %w[news market mortgage investment].freeze

  def index
    @category = params[:category].presence
    @tag      = normalize_tag(params[:tag])
    scope     = Article.public_facing
    scope     = scope.where(category: @category) if @category && Article::CATEGORIES.include?(@category)
    scope     = scope.where(category: FEED_CATEGORIES) unless @category
    scope     = apply_tag_filter(scope, @tag) if @tag
    @articles = scope.page(params[:page]).per(12).to_a
    @macro    = safe_macro
    @counts   = Article.published.visible.where(category: FEED_CATEGORIES)
                       .reorder(nil).group(:category).count

    # ?article=slug — auto-open modal for that article. If it isn't already in
    # the page's listing (different category/tag/page), prepend it so the
    # modal-template partial has the body markup to clone.
    @autoopen_slug = params[:article].presence
    if @autoopen_slug
      extra = Article.public_facing.friendly.find_by(slug: @autoopen_slug)
      @articles = ([extra] + @articles).uniq(&:id) if extra
    end

    set_meta_tags(
      title:       'Новости рынка недвижимости — Рязань',
      description: 'Свежие новости рынка недвижимости Рязани: ставки ЦБ РФ, ' \
                   'ипотечные программы, аналитика. Обновляется ежедневно.',
      keywords:    'новости недвижимости, Рязань, ЦБ РФ, ипотека новости, рынок недвижимости',
      canonical:   request.url.split('?').first
    )
  end

  # Legacy per-article page is gone — the modal on /news is the single
  # reading surface now. Redirect any stragglers (Google index, share links,
  # webhook responses) to /news?article=:slug where JS auto-opens the modal.
  def show
    article = Article.friendly.find(params[:id])
    article.increment!(:views_count) if article.published? && !article.hidden?
    redirect_to news_path(article: article.slug), status: :moved_permanently
  rescue ActiveRecord::RecordNotFound
    redirect_to news_path, alert: 'Статья не найдена.'
  end

  private

  # Strip leading `#` and whitespace. Chat-host hashtags arrive with `#`,
  # but URL tag-params usually don't — accept both, store clean form.
  def normalize_tag(value)
    cleaned = value.to_s.strip.delete_prefix('#').strip
    cleaned.presence
  end

  # Postgres jsonb containment: metadata.hashtags is an array; @> checks
  # array contains element. We OR two variants because the chat-host
  # stores them with `#` prefix but humans link/type without it.
  def apply_tag_filter(scope, tag)
    with_hash    = ["##{tag}"].to_json
    without_hash = [tag].to_json
    scope.where(
      "(articles.metadata->'hashtags') @> ?::jsonb OR " \
      "(articles.metadata->'hashtags') @> ?::jsonb",
      with_hash, without_hash
    )
  end

  # Embedding-based related when available, fallback to category match.
  # Cosine distance: 0.0 = identical, 1.0 = orthogonal. Threshold 0.7
  # prevents off-topic suggestions when corpus is sparse.
  def fetch_related(article, limit: 3)
    emb = article.article_embedding
    if emb&.embedding.present?
      neighbor_recs = ArticleEmbedding
                        .nearest_neighbors(:embedding, emb.embedding, distance: 'cosine')
                        .where.not(article_id: article.id)
                        .limit(limit * 2)
      ids_with_distance = neighbor_recs.each_with_object({}) do |ne, acc|
        next if ne.neighbor_distance.to_f > 0.7
        acc[ne.article_id] = ne.neighbor_distance.to_f
      end
      return category_fallback(article, limit) if ids_with_distance.empty?
      Article.public_facing.where(id: ids_with_distance.keys)
             .sort_by { |a| ids_with_distance[a.id] }
             .first(limit)
    else
      category_fallback(article, limit)
    end
  rescue StandardError => e
    Rails.logger.warn("[NewsController#fetch_related] #{e.class}: #{e.message}")
    category_fallback(article, limit)
  end

  def category_fallback(article, limit)
    Article.public_facing.where(category: article.category)
           .where.not(id: article.id).limit(limit).to_a
  end

  def adjacent_article(article, direction)
    if direction == :newer
      Article.public_facing.where('published_at > ?', article.published_at)
             .reorder(published_at: :asc).first
    else
      Article.public_facing.where('published_at < ?', article.published_at)
             .reorder(published_at: :desc).first
    end
  end

  def safe_macro
    MacroRatesService.call || fallback_macro
  rescue StandardError
    fallback_macro
  end

  def fallback_macro
    { key_rate: nil, mortgage_rate: nil, deposit_rate: nil, stale: true }
  end
end
