# frozen_string_literal: true

class SitemapController < ApplicationController
  def index
    @properties = Property.published.order(updated_at: :desc).limit(1000)
    # Articles join the property listings — blog posts are crawlable URLs
    # with substantive content (≥600 words) so they don't risk soft-404.
    @articles   = Article.published.recent.limit(500)
    respond_to do |format|
      format.xml
    end
  end
end
