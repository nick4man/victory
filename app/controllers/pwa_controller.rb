# frozen_string_literal: true

class PwaController < ApplicationController
  # service-worker.js is requested via a <script>-like fetch by the browser's
  # SW registration. Rails' default verify_same_origin_request filter rejects
  # cross-origin JS to mitigate JSON hijacking — but for SW it kills the file
  # with a 422. Same-origin-by-spec, so opting out is safe here.
  skip_forgery_protection only: :service_worker

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
