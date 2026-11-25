# frozen_string_literal: true

require 'rails_helper'

# Антиспам-гейт Forms::ServiceRequestsController (issue #262, часть 2):
# модалка со страницы /services создаёт Inquiry; до гейта защиты не было
# вообще (skip_before_action :verify_authenticity_token). Дроп молчаливый —
# ответ формы успеха, без записи (образец #255).
RSpec.describe 'Антиспам-гейт /forms/service_request', type: :request do
  around do |example|
    old = ENV.fetch('TG_WORK_BOT_DISABLED', nil)
    ENV['TG_WORK_BOT_DISABLED'] = 'true'
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_cache
    old.nil? ? ENV.delete('TG_WORK_BOT_DISABLED') : ENV['TG_WORK_BOT_DISABLED'] = old
    travel_back
  end

  # Токен со страницы минтится ДО travel: иначе rendered_at свежее
  # MIN_FILL_SECONDS и гейт дропает сабмит как too_fast.
  def fresh_token
    get services_page_path
    token = response.parsed_body.at_css('input[name="rendered_at_token"]')&.[]('value')
    travel 5.seconds
    token
  end

  let(:request_params) do
    { service_slug: 'sell', name: 'Иван Петров', phone: '+79001234567',
      email: 'ivan@example.com', message: 'Помогите продать квартиру' }
  end

  it 'GET /services: модалка заявки несёт honeypot и подписанный timestamp' do
    get services_page_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(PublicFormSpamGate::HONEYPOT_PARAM.to_s)
    expect(response.body).to include('rendered_at_token')
  end

  it 'нормальный сабмит с token создаёт Inquiry' do
    expect do
      post forms_service_request_path, params: request_params.merge(rendered_at_token: fresh_token)
    end.to change(Inquiry, :count).by(1)

    expect(response).to redirect_to(services_page_path)
    expect(flash[:notice]).to eq('Заявка получена. Менеджер свяжется с вами в ближайшее время.')
  end

  it 'дропает заполненный honeypot: success-redirect, без Inquiry' do
    token = fresh_token
    expect do
      post forms_service_request_path,
           params: request_params.merge(rendered_at_token: token,
                                        PublicFormSpamGate::HONEYPOT_PARAM => 'http://buy-cheap-links.example')
    end.not_to change(Inquiry, :count)

    expect(response).to redirect_to(services_page_path)
    expect(flash[:notice]).to eq('Заявка получена. Менеджер свяжется с вами в ближайшее время.')
  end

  it 'дропает submit без timestamp рендера' do
    expect { post forms_service_request_path, params: request_params }.not_to change(Inquiry, :count)

    expect(response).to redirect_to(services_page_path)
    expect(flash[:notice]).to be_present
  end

  it 'дропает JSON-submit с заблокированного IP: {ok:true}, без Inquiry' do
    SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
    token = fresh_token

    expect do
      post forms_service_request_path,
           params: request_params.merge(rendered_at_token: token),
           headers: { 'REMOTE_ADDR' => '80.94.95.173' },
           as: :json
    end.not_to change(Inquiry, :count)

    expect(response.parsed_body).to eq('ok' => true)
  end

  it 'четвёртый сабмит за час с одного IP дропается молча' do
    3.times do
      token = fresh_token
      cookies.delete('visitor_token')
      expect do
        post forms_service_request_path, params: request_params.merge(rendered_at_token: token)
      end.to change(Inquiry, :count).by(1)
    end

    token = fresh_token
    cookies.delete('visitor_token')
    expect do
      post forms_service_request_path, params: request_params.merge(rendered_at_token: token)
    end.not_to change(Inquiry, :count)

    expect(response).to redirect_to(services_page_path)
    expect(flash[:notice]).to be_present
  end
end
