# frozen_string_literal: true

require 'rails_helper'

# Ссылка «Коммерческая» в шапке с 13.05.26 вела на `/kupit/commerce`: slug
# `commerce` не входит в LANDING_TYPE_RX, и каждая страница сайта отдавала
# посетителю и поисковику ссылку на 404. Пути лендингов в шапке захардкожены
# строками, а маршрут их молча не принимает — поэтому проверяем не одну
# ссылку, а все: каждый такой путь обязан распознаваться роутером.
RSpec.describe 'Ссылки лендингов в шапке сайта', type: :request do
  header = Rails.root.join('app/views/shared/_site_header.html.erb').read
  landing_paths = header.scan(%r{'(/(?:kupit|snyat)/[^']*)'}).flatten.uniq

  it 'находит в шапке пути лендингов (иначе проверка ниже пустая)' do
    expect(landing_paths).to include('/kupit/kommercheskaya')
  end

  landing_paths.each do |path|
    it "#{path} ведёт на лендинг, а не в 404" do
      expect(Rails.application.routes.recognize_path(path, method: :get))
        .to include(controller: 'landings', action: 'show')
    end
  end

  it 'уводит старый /kupit/commerce на /kupit/kommercheskaya с 301' do
    get '/kupit/commerce'
    expect(response).to have_http_status(:moved_permanently)
    expect(response).to redirect_to('/kupit/kommercheskaya')
  end
end
