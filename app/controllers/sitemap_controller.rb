# frozen_string_literal: true

class SitemapController < ApplicationController
  def index
    @properties = Property.published.order(updated_at: :desc).limit(1000)
    # Articles join the property listings — blog posts are crawlable URLs
    # with substantive content (≥600 words) so they don't risk soft-404.
    @articles   = Article.published.recent.limit(500)
    # Public agent profiles — reuses AgentProfile.publicly_listable_agents
    # so /sitemap.xml and /agents/:slug agree on which agents are public.
    @agents = User.publicly_listable_agents.limit(200)
    # Closed-deal case studies (Pillar 2 of strategicVector — deep expertise
    # proof). Public_facing scope mirrors what /cases renders, so sitemap
    # never lists a URL that returns 404 / unpublished.
    @case_studies = CaseStudy.public_facing.limit(500)
    respond_to do |format|
      format.xml
    end
  end

  # Google News sitemap — only articles published in the last 48 hours are
  # eligible (Google drops older entries). Yandex News reads the same schema.
  # Separate route lets us emit news:news structured data without polluting
  # the main sitemap (which would slow crawl of the steady-state catalog).
  def news
    @articles = Article.published
                       .where('published_at >= ?', 2.days.ago)
                       .order(published_at: :desc)
                       .limit(1000)
    respond_to do |format|
      format.xml
    end
  end
end
