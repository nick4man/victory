# frozen_string_literal: true

class PwaController < ApplicationController
  # service-worker.js is requested via a <script>-like fetch by the browser's
  # SW registration. Rails' default verify_same_origin_request filter rejects
  # cross-origin JS to mitigate JSON hijacking — but for SW it kills the file
  # with a 422. Same-origin-by-spec, so opting out is safe here.
  skip_forgery_protection only: :service_worker

  # Web App Manifest — read by Android (Add to Home Screen), iOS Safari,
  # Yandex Browser, and search engines as a hint that the site is mobile-
  # ready. Lighthouse's PWA checklist downgrades any field left empty —
  # filling description/lang/scope/categories cleans those audits.
  def manifest
    render json: {
      name:             'АН «Виктори» — недвижимость в Рязани',
      short_name:       'Виктори',
      description:      'Покупка, продажа и аренда квартир, домов, коммерческой недвижимости в Рязани и Рязанской области.',
      lang:             'ru-RU',
      dir:              'ltr',
      start_url:        '/',
      scope:            '/',
      display:          'standalone',
      orientation:      'portrait-primary',
      background_color: '#ffffff',
      theme_color:      '#0a0a0a',
      categories:       %w[business productivity lifestyle],
      icons:            [
        { src: '/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
        { src: '/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
        { src: '/icon-maskable-192.png', sizes: '192x192', type: 'image/png', purpose: 'maskable' },
        { src: '/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' }
      ],
      shortcuts: [
        { name: 'Каталог',  short_name: 'Каталог',  url: '/properties', description: 'Все объекты недвижимости' },
        { name: 'Контакты', short_name: 'Контакты', url: '/contacts',   description: 'Связаться с агентством' }
      ]
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
