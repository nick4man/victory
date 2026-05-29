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
    include AdminTokenAuth
    layout 'application'
    before_action :set_article, only: %i[show edit update hide unhide publish publish_to_telegram destroy]

    def index
      @scope    = params[:scope].presence || 'visible'
      @category = params[:category].presence if Article::CATEGORIES.include?(params[:category])
      base = Article.order(created_at: :desc)
      base = base.where(category: @category) if @category
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
        tg_msg = maybe_post_to_telegram(@article)
        flash[:notice] = ['Статья создана.', tg_msg].compact.join(' ')
        redirect_to admin_articles_path
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @article.update(article_params)
        redirect_to admin_articles_path, notice: 'Сохранено.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def hide
      @article.hide!
      redirect_back fallback_location: admin_articles_path,
                    notice: "Статья «#{@article.title.truncate(50)}» скрыта."
    end

    def unhide
      @article.unhide!
      redirect_back fallback_location: admin_articles_path,
                    notice: "Статья восстановлена."
    end

    def publish
      @article.update!(published_at: Time.current)
      redirect_back fallback_location: admin_articles_path, notice: 'Опубликовано.'
    end

    # POST /admin/articles/:id/publish_to_telegram — ad-hoc TG dispatch for an
    # already-saved article. Idempotent: refuses if `metadata.telegram_message_id`
    # is set (chat-host post or a previous click).
    def publish_to_telegram
      result = Articles::TelegramPublisher.new(@article).call
      if result[:success]
        redirect_back fallback_location: edit_admin_article_path(@article),
                      notice: "Опубликовано в @rznvictory (msg ##{result[:message_id]})."
      else
        redirect_back fallback_location: edit_admin_article_path(@article),
                      alert: "TG: #{result[:error]}"
      end
    end

    def destroy
      @article.destroy
      redirect_to admin_articles_path, notice: 'Удалено.'
    end

    private

    def set_article
      @article = Article.find(params[:id])
    end

    def article_params
      params.require(:article).permit(:title, :slug, :excerpt, :body, :category,
                                      :region, :schema_type, :published_at)
    end

    def publish_now?
      params[:publish] == '1' || params[:publish] == 'true'
    end

    # If the admin checked «Также опубликовать в Telegram» during creation,
    # fire the publisher synchronously and return a flash-friendly summary.
    # Errors don't block the create — the article exists either way.
    def maybe_post_to_telegram(article)
      return nil unless params[:publish_to_telegram] == '1'

      result = Articles::TelegramPublisher.new(article).call
      if result[:success]
        "В Telegram: опубликовано (msg ##{result[:message_id]})."
      else
        "TG не отправлено: #{result[:error]}."
      end
    end
  end
end
