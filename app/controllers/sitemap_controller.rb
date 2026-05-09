# frozen_string_literal: true

class SitemapController < ApplicationController
  def index
    @properties = Property.published.order(updated_at: :desc).limit(1000)
    respond_to do |format|
      format.xml
    end
  end
end
