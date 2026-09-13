# frozen_string_literal: true

require 'rails_helper'

# Ссылка «Коммерческая» в шапке с 13.05.26 вела на `/kupit/commerce`: slug
# `commerce` не входит в LANDING_TYPE_RX, запрос проваливался в catch-all
# `errors#not_found`, и каждая страница сайта отдавала посетителю и поисковику
# ссылку на 404. Пути лендингов в шапке захардкожены строками, а роутер их
# молча не принимает — поэтому проверяем не одну ссылку, а все: каждый такой
# путь обязан распознаваться как лендинг.
RSpec.describe 'Ссылки лендингов в шапке сайта', type: :request do
  # Литералы в любых кавычках; строки с интерполяцией (`#{slug}`) пропускаем —
  # их значение известно только при рендере.
  header = Rails.root.join('app/views/shared/_site_header.html.erb').read
  landing_paths = header.scan(%r{['"](/(?:kupit|snyat)/[^'"#]*)['"]}).flatten.uniq
  # Пустой список дал бы ноль примеров и зелёный прогон ни о чём — падаем громко.
  raise 'в шапке не найдено ни одного пути лендинга — проверь регулярку' if landing_paths.empty?

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
