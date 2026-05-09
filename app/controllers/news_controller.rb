# frozen_string_literal: true

class NewsController < ApplicationController
  include ComingSoonSection

  def index
    render_coming_soon('Новости', 'Раздел новостей агентства в разработке.')
  end

  def show
    render_coming_soon('Новости')
  end
end
