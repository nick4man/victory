# frozen_string_literal: true

class PwaController < ApplicationController
  def manifest
    render json: {
      name: 'АН Виктори',
      short_name: 'Виктори',
      start_url: '/',
      display: 'standalone',
      theme_color: '#dc2626',
      background_color: '#ffffff'
    }
  end

  def service_worker
    render js: ''
  end
end
