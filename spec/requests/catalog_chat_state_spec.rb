# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Catalog page renders chat-state filters', type: :request do
  it 'renders 200 with ransack filter params (regression: params[:q].to_h → 500)' do
    create(:property, :on_site, price: 5_000_000, area: 50, rooms: 2)

    get '/properties', params: { q: { rooms_eq: 2, price_gteq: 1_000_000 } }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-chat-state="filters"')
    expect(response.body).to include('2-комн.')
  end
end
