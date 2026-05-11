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
    @category  = params[:category].presence
    scope      = Article.public_facing
    scope      = scope.where(category: @category) if @category && Article::CATEGORIES.include?(@category)
    scope      = scope.where(category: FEED_CATEGORIES) unless @category
    @articles  = scope.page(params[:page]).per(12)
    @macro     = safe_macro
    @counts    = Article.published.visible.where(category: FEED_CATEGORIES)
                        .reorder(nil).group(:category).count

    set_meta_tags(
      title:       'Новости рынка недвижимости — Рязань',
      description: 'Свежие новости рынка недвижимости Рязани: ставки ЦБ РФ, ' \
                   'ипотечные программы, аналитика. Обновляется ежедневно.',
      keywords:    'новости недвижимости, Рязань, ЦБ РФ, ипотека новости, рынок недвижимости',
      canonical:   request.url.split('?').first
    )
  end

  def show
    @article = Article.friendly.find(params[:id])
    if @article.hidden? || !@article.published?
      redirect_to news_path, alert: 'Эта статья сейчас недоступна.' and return
    end
    @article.increment!(:views_count)
    @related = Article.public_facing
                       .where(category: @article.category)
                       .where.not(id: @article.id)
                       .limit(3)

    set_meta_tags(
      title:       @article.title,
      description: @article.short_excerpt(length: 160),
      canonical:   news_item_url(@article.slug),
      og: { type: 'article', title: @article.title, description: @article.short_excerpt(length: 160) }
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to news_path, alert: 'Статья не найдена.'
  end

  private

  def safe_macro
    MacroRatesService.call || fallback_macro
  rescue StandardError
    fallback_macro
  end

  def fallback_macro
    { key_rate: nil, mortgage_rate: nil, deposit_rate: nil, stale: true }
  end
end
