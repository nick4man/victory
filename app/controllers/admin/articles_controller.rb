# frozen_string_literal: true

module Admin
  # Token-guarded article moderation + manual creation. Mirrors the pattern
  # used by Admin::ReviewsController. Devise is disabled site-wide, so we
  # rely on a shared `?token=$ADMIN_TOKEN` query param. Replace with Pundit
  # when auth returns.
  #
  # Use-cases:
  #   - moderate auto-ingested articles (hide/unhide bad LLM outputs)
  #   - publish drafts (set published_at)
  #   - create manual "site update" articles
  class ArticlesController < ApplicationController
    layout 'application'
    before_action :require_admin_token
    before_action :set_article, only: %i[show edit update hide unhide publish destroy]

    def index
      @scope = params[:scope].presence || 'visible'
      base = Article.order(created_at: :desc)
      @articles = case @scope
                  when 'hidden'  then base.where.not(hidden_at: nil)
                  when 'pending' then base.where(published_at: nil)
                  else                base.where(hidden_at: nil)
                  end
      @articles = @articles.page(params[:page]).per(30)
      @counts = {
        visible: Article.where(hidden_at: nil).count,
        hidden:  Article.where.not(hidden_at: nil).count,
        pending: Article.where(published_at: nil).count
      }
    end

    def show; end

    def new
      @article = Article.new(category: 'news', schema_type: 'NewsArticle')
    end

    def create
      @article = Article.new(article_params.merge(
        external_source: 'manual',
        published_at: publish_now? ? Time.current : nil
      ))
      if @article.save
        redirect_to admin_articles_path(token: params[:token]), notice: 'Статья создана.'
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @article.update(article_params)
        redirect_to admin_articles_path(token: params[:token]), notice: 'Сохранено.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def hide
      @article.hide!
      redirect_back fallback_location: admin_articles_path(token: params[:token]),
                    notice: "Статья «#{@article.title.truncate(50)}» скрыта."
    end

    def unhide
      @article.unhide!
      redirect_back fallback_location: admin_articles_path(token: params[:token]),
                    notice: "Статья восстановлена."
    end

    def publish
      @article.update!(published_at: Time.current)
      redirect_back fallback_location: admin_articles_path(token: params[:token]), notice: 'Опубликовано.'
    end

    def destroy
      @article.destroy
      redirect_to admin_articles_path(token: params[:token]), notice: 'Удалено.'
    end

    private

    def set_article
      @article = Article.find(params[:id])
    end

    def require_admin_token
      expected = ENV['ADMIN_TOKEN']
      head :forbidden and return if expected.blank?
      head :forbidden and return unless ActiveSupport::SecurityUtils.secure_compare(params[:token].to_s, expected)
    end

    def article_params
      params.require(:article).permit(:title, :slug, :excerpt, :body, :category,
                                      :region, :schema_type, :published_at)
    end

    def publish_now?
      params[:publish] == '1' || params[:publish] == 'true'
    end
  end
end
