# frozen_string_literal: true

class SitemapController < ApplicationController
  def index
    @properties = Property.published.select(:id, :slug, :updated_at).order(updated_at: :desc)
    @static_pages = static_pages

    respond_to do |format|
      format.xml { render layout: false }
    end
  end

  private

  def static_pages
    [
      { loc: root_url,            priority: '1.0', changefreq: 'daily' },
      { loc: properties_url,      priority: '0.9', changefreq: 'hourly' },
      { loc: about_url,           priority: '0.5', changefreq: 'monthly' },
      { loc: contacts_url,        priority: '0.5', changefreq: 'monthly' },
      { loc: services_page_url,   priority: '0.6', changefreq: 'monthly' },
      { loc: faq_url,             priority: '0.4', changefreq: 'monthly' },
      { loc: privacy_url,         priority: '0.3', changefreq: 'yearly' },
      { loc: terms_url,           priority: '0.3', changefreq: 'yearly' }
    ]
  end
end
