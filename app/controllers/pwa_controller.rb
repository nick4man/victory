# frozen_string_literal: true

class PwaController < ApplicationController
  def manifest
    render json: {
      name: 'АН Виктори',
      short_name: 'Виктори',
      start_url: '/',
      display: 'standalone',
      background_color: '#ffffff',
      theme_color: '#0066cc',
      icons: []
    }
  end

  def service_worker
    render plain: "// service worker placeholder\nself.addEventListener('install', e => self.skipWaiting());\n",
           content_type: 'application/javascript'
  end

  def offline
    render html: '<!DOCTYPE html><html><body><h1>Нет соединения</h1></body></html>'.html_safe
  end
end
