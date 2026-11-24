# frozen_string_literal: true

require 'rails_helper'

# Issue #261: мёртвые стабы Forms::{QuickInquiries,CallbackRequests,
# ViewingRequests,AgentContacts,MortgageRequests,ConsultationRequests}
# выключены — POST-роуты сняты, контроллеры удалены. Их единственное
# поведение было log+redirect без сохранения, т.е. публичные точки,
# бесполезные людям и открытые ботам.
RSpec.describe 'Снятые роуты мёртвых форм-стабов', type: :request do
  around do |example|
    old = ENV.fetch('TG_WORK_BOT_DISABLED', nil)
    ENV['TG_WORK_BOT_DISABLED'] = 'true'
    example.run
    old.nil? ? ENV.delete('TG_WORK_BOT_DISABLED') : ENV['TG_WORK_BOT_DISABLED'] = old
  end

  %w[
    /forms/quick_inquiry
    /forms/callback_request
    /forms/viewing_request
    /forms/agent_contact
    /forms/mortgage_request
    /forms/consultation_request
  ].each do |path|
    it "POST #{path} больше не существует (404)" do
      post path, params: { phone: '+7 DISPOSABLE' }
      expect(response).to have_http_status(:not_found)
    end
  end

  it 'живой роут Forms::ServiceRequests остаётся (часть 2 его не трогает)' do
    expect(Rails.application.routes.url_helpers.respond_to?(:forms_service_request_path)).to be true
  end

  it 'CTA-партиал главной больше не ссылается на мёртвый стаб' do
    # home/index (легаси-страница без роута) рендерит _cta_form; проверяем
    # сам партиал — его action обязан вести в живой /contact_forms/quick_inquiry.
    partial = File.read(Rails.root.join('app/views/home/_cta_form.html.erb'))
    expect(partial).not_to match(/[^_]forms_quick_inquiry_path/)
    expect(partial).to include('contact_forms_quick_inquiry_path')
  end
end
