# frozen_string_literal: true

# Serves /blog (index), /blog/:slug (show), /blog/category/:category.
# Powered by the Article model — Markdown source rendered into body_html on
# save, displayed via the show view with Schema.org NewsArticle / BlogPosting.
class BlogController < ApplicationController
  before_action :set_per_page, only: %i[index category]

  # Category hub-pages metadata — H1, meta description, intro text per category.
  # Используется в #category action для CTR-optimized SERP snippets + internal
  # topical authority signal. Keys must match Article::CATEGORIES.
  CATEGORY_META = {
    'market' => {
      h1: 'Аналитика рынка недвижимости',
      description: 'Свежие обзоры цен, динамики спроса и тренды рынка недвижимости Рязани, Москвы и СПб от АН «Виктори». Еженедельные дайджесты от экспертов с 18-летним опытом.',
      intro: 'Каждую неделю — обзор движения цен, доступности ипотеки и локальных трендов. Базируется на нашей закрытой базе сделок.'
    },
    'guides' => {
      h1: 'Гайды по покупке недвижимости',
      description: 'Пошаговые руководства: как проверить квартиру, оформить ипотеку, выбрать район. Чек-листы и инструкции от риелторов АН «Виктори».',
      intro: 'Подробные инструкции от наших агентов — без воды, по делу.'
    },
    'news' => {
      h1: 'Новости рынка недвижимости',
      description: 'Срочные новости рынка недвижимости, изменения ключевой ставки ЦБ, банковские программы ипотеки. Обновляется ежедневно.',
      intro: 'Срочные новости с комментариями от экспертов АН «Виктори».'
    },
    'investment' => {
      h1: 'Инвестиции в недвижимость',
      description: 'Доходные стратегии в недвижимости Рязани: аренда, флиппинг, новостройки. Анализ окупаемости от инвест-аналитиков АН «Виктори».',
      intro: 'Стратегии для инвесторов: что покупать, как считать доходность.'
    },
    'mortgage' => {
      h1: 'Ипотека — программы и калькуляторы',
      description: 'Актуальные ипотечные программы банков-партнёров АН «Виктори», расчёт платежей, льготные программы (семейная, IT, дальневосточная).',
      intro: 'Все ипотечные программы Сбера, ВТБ, Альфы и др. в одном месте.'
    }
  }.freeze

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
    return redirect_to(blog_path, alert: 'Категория не найдена') unless Article::CATEGORIES.include?(@category)

    meta = CATEGORY_META.fetch(@category)
    @h1 = meta[:h1]
    @meta_description = meta[:description]
    @intro = meta[:intro]
    @articles = Article.public_facing
                       .where(category: @category)
                       .page(params[:page])
                       .per(@per_page || 12)
    add_breadcrumb 'Блог', blog_path
    add_breadcrumb @h1
    render :category
  end

  private

  def set_per_page
    @per_page = (respond_to?(:per_page) ? per_page : 12)
  end
end
