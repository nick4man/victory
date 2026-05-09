# frozen_string_literal: true

class BlogController < ApplicationController
  include ComingSoonSection

  def index
    render_coming_soon('Блог', 'Скоро здесь появятся статьи о недвижимости, инвестициях и рынке.')
  end

  def show
    render_coming_soon('Блог')
  end

  def category
    render_coming_soon("Блог: #{params[:category]}")
  end
end
