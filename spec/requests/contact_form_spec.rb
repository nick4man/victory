# frozen_string_literal: true

require 'rails_helper'

# Антиспам для формы обратной связи /contacts (issue #223): honeypot-поле
# + тайминг рендера. Автоматическая отправка (curl/скрипт, без JS) не должна
# создавать Inquiry; ручная отправка человеком — работает без изменений.
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
  # важен сам факт создания/отсутствия Inquiry, работу intake покрывают
  # свои спеки — отключаем внешний пуш.
  around do |example|
    old = ENV.fetch('TG_WORK_BOT_DISABLED', nil)
    ENV['TG_WORK_BOT_DISABLED'] = 'true'
    example.run
    old.nil? ? ENV.delete('TG_WORK_BOT_DISABLED') : ENV['TG_WORK_BOT_DISABLED'] = old
  end

  describe 'POST /contacts (send_contact_form)' do
    it 'создаёт Inquiry при нормальном прохождении' do
      get contacts_path
      travel 5.seconds

      expect { post send_contact_form_path, params: valid_params }
        .to change(Inquiry, :count).by(1)

      inquiry = Inquiry.order(:id).last
      expect(inquiry.source).to eq 'contact_form'
      expect(inquiry.name).to eq 'Иван Петров'
      expect(response).to redirect_to(contacts_path)
      expect(flash[:notice]).to be_present
    end

    it 'не создаёт Inquiry при заполненном honeypot-поле' do
      get contacts_path
      travel 5.seconds

      expect do
        post send_contact_form_path,
             params: valid_params.merge(website: 'http://buy-cheap-links.example')
      end.not_to change(Inquiry, :count)

      # Молчаливый дроп: для бота ответ неотличим от успеха.
      expect(response).to redirect_to(contacts_path)
      expect(flash[:notice]).to be_present
    end

    it 'не создаёт Inquiry при отправке быстрее MIN_FILL_SECONDS после рендера' do
      get contacts_path

      expect { post send_contact_form_path, params: valid_params }
        .not_to change(Inquiry, :count)
    end

    it 'не создаёт Inquiry при POST без визита на /contacts (нет timestamp рендера)' do
      expect { post send_contact_form_path, params: valid_params }
        .not_to change(Inquiry, :count)
    end

    it 'timestamp рендера одноразовый: повторный POST сразу дропается' do
      get contacts_path
      travel 5.seconds
      post send_contact_form_path, params: valid_params
      expect(Inquiry.count).to eq(1)

      expect { post send_contact_form_path, params: valid_params }
        .not_to change(Inquiry, :count)
    end

    it 'после повторного GET /contacts форма снова принимается' do
      get contacts_path
      travel 5.seconds
      post send_contact_form_path, params: valid_params

      get contacts_path
      travel 5.seconds
      expect { post send_contact_form_path, params: valid_params }
        .to change(Inquiry, :count).by(1)
    end
  end
end
