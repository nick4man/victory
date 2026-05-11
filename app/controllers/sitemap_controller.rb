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
    respond_to do |format|
      format.xml
    end
  end
end
