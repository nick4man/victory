# frozen_string_literal: true

class SitemapController < ApplicationController
  # /sitemap.xml — sitemap-index format. Перечисляет sub-sitemaps по
  # частоте изменения, чтобы Я./Google могли независимо crawl-ить
  # high-traffic listings vs slow-change pages. lastmod на каждый
  # sub-sitemap = max(updated_at) его entities + 1 day fallback.
  def index
    @pages_mod    = Date.current.iso8601
    @listings_mod = (Property.published.maximum(:updated_at) || Time.current).iso8601
    @blog_mod     = [
      Article.respond_to?(:published) ? Article.published.maximum(:updated_at) : nil,
      CaseStudy.respond_to?(:public_facing) ? CaseStudy.public_facing.maximum(:updated_at) : nil,
      User.respond_to?(:publicly_listable_agents) ? User.publicly_listable_agents.maximum(:updated_at) : nil
    ].compact.max&.iso8601 || @pages_mod
    respond_to(&:xml)
  end

  # /sitemap-pages.xml — static + SEO district landings + premium variants.
  # Slow-change bucket (monthly/yearly priority). Я. может crawl-ить раз в
  # неделю — содержимое RyazanDistricts constant + page copy.
  def pages
    # Ровно то же множество, что показывает хаб `/zhk` — одна выборка
    # (`hub_listed`) на двоих. `sitemap_ready` строго уже, чем `indexable?`
    # (см. комментарий класса ResidentialComplex): предлагать краулеру
    # обойти карточку, на которой нечего читать, — тратить crawl-квоту на
    # страницу, которая всё равно не ранжируется. Фильтр по городу — часть
    # той же выборки: не-рязанский ЖК хаб не перечисляет, значит и в
    # sitemap он попал бы орфаном без единой входящей ссылки.
    @complexes = ResidentialComplex.hub_listed
    # Сам хаб — только когда он же отдаёт индексируемую страницу. Раньше он
    # стоял в sitemap безусловно и на пустом справочнике (а на проде он
    # пуст) уезжал туда с `noindex,follow` на борту.
    @hub_indexable = ResidentialComplex.hub_indexable?(@complexes)
    respond_to(&:xml)
  end

  # /sitemap-listings.xml — property pages with image:image entries. Highest
  # crawl frequency (hourly) — самая динамичная часть каталога.
  def listings
    @properties = Property.published.order(updated_at: :desc).limit(1000)
    respond_to(&:xml)
  end

  # /sitemap-blog.xml — articles + case studies + agent profiles. Medium-
  # change bucket. Articles add content weekly, agents change rarely,
  # case-studies — when закрытая сделка публикуется.
  def blog
    @articles     = Article.published.visible.recent.limit(500)
    @agents       = User.publicly_listable_agents.limit(200)
    @case_studies = CaseStudy.public_facing.limit(500)
    respond_to(&:xml)
  end

  # Google News sitemap — only articles published in the last 48 hours are
  # eligible (Google drops older entries). Yandex News reads the same schema.
  # Separate route lets us emit news:news structured data without polluting
  # the main sitemap (which would slow crawl of the steady-state catalog).
  #
  # Visible scope ОБЯЗАТЕЛЕН — `Article.published` alone не фильтрует
  # `hidden_at IS NOT NULL` (admin-hidden articles). Без visible они бы
  # попадали в news-sitemap → conflict с noindex на самой странице.
  def news
    # Pure news-feed: category=news ONLY. Guides/market/investment statьи
    # бывают long-form, не подходят под Google/Я.News spec (свежие новости).
    # Если попадут — Я.News crawler downgrade'нет наш news-sitemap reliability.
    @articles = Article.published.visible.in_category('news')
                       .where('published_at >= ?', 2.days.ago)
                       .order(published_at: :desc)
                       .limit(1000)
    respond_to do |format|
      format.xml
    end
  end
end
