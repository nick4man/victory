# frozen_string_literal: true

class RobotsController < ApplicationController
  def index
    respond_to do |format|
      format.text { render layout: false, content_type: 'text/plain' }
    end
  end
end
