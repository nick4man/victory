# frozen_string_literal: true

require 'rails_helper'

# Антиспам для формы обратной связи /contacts (issue #239):
# - honeypot — молчаливый дроп;
# - тайминговые сигналы — заявка сохраняется как suspicious;
# - timestamp рендера передаётся подписанным скрытым полем,
#   не сессия — работает без cookie и после bfcache.
RSpec.describe 'Форма обратной связи /contacts', type: :request do
  let(:valid_params) do
    {
      name: 'Иван Петров',
      phone: '+79001234567',
      email: 'ivan@example.com',
      message: 'Хочу купить двухкомнатную квартиру в центре'
    }
  end

  # Inquiry#push_to_work_bot → Lead::Intake → TG-анонсер: в request-спеке
  # важен сам факт создания/-пометки Inquiry, работу intake покрывают
  # свои спеки — отключаем внешний пуш.
  around do |example|
    old = ENV.fetch('TG_WORK_BOT_DISABLED', nil)
    ENV['TG_WORK_BOT_DISABLED'] = 'true'
    Rails.cache.clear
    example.run
    old.nil? ? ENV.delete('TG_WORK_BOT_DISABLED') : ENV['TG_WORK_BOT_DISABLED'] = old
    travel_back
  end

  def rendered_at_token_from_page
    response.parsed_body.at_css('input[name="rendered_at_token"]')&.[]('value')
  end

  describe 'POST /contacts (send_contact_form)' do
    it 'создаёт Inquiry при нормальном прохождении' do
      get contacts_path
      token = rendered_at_token_from_page
      travel 5.seconds

      expect { post send_contact_form_path, params: valid_params.merge(rendered_at_token: token) }
        .to change(Inquiry, :count).by(1)

      inquiry = Inquiry.order(:id).last
      expect(inquiry.source).to eq 'contact_form'
      expect(inquiry.name).to eq 'Иван Петров'
      expect(inquiry.metadata).to be_blank
      expect(response).to redirect_to(contacts_path)
      expect(flash[:notice]).to be_present
    end

    it 'не создаёт Inquiry при заполненном honeypot-поле' do
      get contacts_path
      token = rendered_at_token_from_page
      travel 5.seconds

      expect do
        post send_contact_form_path,
             params: valid_params.merge(
               rendered_at_token: token,
               ContactFormSpamGuard::HONEYPOT_PARAM => 'http://buy-cheap-links.example'
             )
      end.not_to change(Inquiry, :count)

      # Молчаливый дроп: для бота ответ неотличим от успеха.
      expect(response).to redirect_to(contacts_path)
      expect(flash[:notice]).to be_present
    end

    it 'создаёт подозрительную Inquiry при отправке быстрее MIN_FILL_SECONDS после рендера' do
      get contacts_path
      token = rendered_at_token_from_page

      expect { post send_contact_form_path, params: valid_params.merge(rendered_at_token: token) }
        .to change(Inquiry, :count).by(1)

      inquiry = Inquiry.order(:id).last
      expect(inquiry.metadata).to include('contact_form_spam_reason' => 'too_fast', 'suspicious' => true)
      expect(response).to redirect_to(contacts_path)
      expect(flash[:notice]).to be_present
    end

    it 'создаёт подозрительную Inquiry при POST без визита на /contacts (нет токена)' do
      expect { post send_contact_form_path, params: valid_params }
        .to change(Inquiry, :count).by(1)

      inquiry = Inquiry.order(:id).last
      expect(inquiry.metadata).to include('contact_form_spam_reason' => 'no_render_timestamp', 'suspicious' => true)
    end

    it 'сохраняет заявку при повторной отправке без нового токена' do
      get contacts_path
      travel 5.seconds
      post send_contact_form_path, params: valid_params.merge(rendered_at_token: rendered_at_token_from_page)
      expect(Inquiry.count).to eq(1)

      # Повторный POST без нового токена — подозрительно, но не теряется.
      expect { post send_contact_form_path, params: valid_params }
        .to change(Inquiry, :count).by(1)
      expect(Inquiry.order(:id).last.metadata).to include('contact_form_spam_reason' => 'no_render_timestamp')
    end

    it 'после повторного GET /contacts форма снова принимается' do
      get contacts_path
      travel 5.seconds
      post send_contact_form_path, params: valid_params.merge(rendered_at_token: rendered_at_token_from_page)

      get contacts_path
      travel 5.seconds
      expect { post send_contact_form_path, params: valid_params.merge(rendered_at_token: rendered_at_token_from_page) }
        .to change(Inquiry, :count).by(1)
    end
  end
end
