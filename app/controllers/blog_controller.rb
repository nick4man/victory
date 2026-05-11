# frozen_string_literal: true

# Serves /blog (index), /blog/:slug (show), /blog/category/:category.
# Powered by the Article model — Markdown source rendered into body_html on
# save, displayed via the show view with Schema.org NewsArticle / BlogPosting.
class BlogController < ApplicationController
  before_action :set_per_page, only: %i[index category]

  def index
    @articles = Article.published
                       .in_category(params[:category])
                       .recent
                       .page(params[:page])
                       .per(@per_page || 12)
    @category = params[:category]
    add_breadcrumb 'Блог', blog_path
    add_breadcrumb @category.to_s.humanize if @category.present?
  end

  def show
    @article = Article.friendly.find(params[:slug])
    @related = Article.published
                      .in_category(@article.category)
                      .where.not(id: @article.id)
                      .recent
                      .limit(3)
    @article.increment!(:views_count) rescue nil
    add_breadcrumb 'Блог', blog_path
    add_breadcrumb @article.title
  rescue ActiveRecord::RecordNotFound
    redirect_to blog_path, alert: 'Статья не найдена'
  end

  def category
    @category = params[:category]
    @articles = Article.published
                       .where(category: @category)
                       .recent
                       .page(params[:page])
                       .per(@per_page || 12)
    add_breadcrumb 'Блог', blog_path
    add_breadcrumb @category.to_s.humanize
    render :index
  end

  private

  def set_per_page
    @per_page = (respond_to?(:per_page) ? per_page : 12)
  end
end
