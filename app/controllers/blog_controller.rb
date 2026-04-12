# frozen_string_literal: true

class BlogController < ApplicationController
  def index
    @posts = []
  end

  def show
    redirect_to blog_index_path
  end
end
