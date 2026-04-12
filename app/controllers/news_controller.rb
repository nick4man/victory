# frozen_string_literal: true

class NewsController < ApplicationController
  def index
    @articles = []
  end

  def show
    redirect_to news_index_path
  end
end
