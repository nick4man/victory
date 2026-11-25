# frozen_string_literal: true

require 'rails_helper'

# Антиспам-гейт заявочных форм /contact_forms/* (issue #262, часть 2):
# общий PublicFormSpamGate до создания Inquiry и до всех mailer'ов
# (CSRF для JSON выключен — эндпоинты открыты ботам, а каждая заявка жжёт
# почту, включая confirmation на email из формы). Дроп молчаливый: ответ
# неотличим от принятой заявки (образец #255).
RSpec.describe 'Антиспам-гейт /contact_forms/*', type: :request do
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

  let(:inquiry_params) do
    { name: 'Иван Петров', phone: '+79001234567', email: 'ivan@example.com', message: 'Ищу двухкомнатную квартиру' }
  end

  # Токен минтится ДО travel: иначе rendered_at свежее MIN_FILL_SECONDS
  # и гейт дропает сабмит как too_fast.
  def fresh_token
    token = PublicFormSpamGate.rendered_at_token
    travel 5.seconds
    token
  end

  def submit_quick_inquiry(extra = {}, headers: {})
    post contact_forms_quick_inquiry_path,
         params: { inquiry: inquiry_params }.merge(extra),
         headers: headers
  end

  describe 'POST /contact_forms/quick_inquiry — нормальный сабмит' do
    it 'создаёт Inquiry и ставит оба mailer' do
      expect { submit_quick_inquiry({ rendered_at_token: fresh_token }) }
        .to change(Inquiry, :count).by(1)
        .and have_enqueued_job(ActionMailer::MailDeliveryJob).at_least(:once)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq('Спасибо! Ваша заявка принята. Мы свяжемся с вами в ближайшее время.')
    end
  end

  describe 'молчаливый дроп quick_inquiry (образец #255)' do
    it 'дропает заполненный honeypot: success-ответ, без Inquiry и mailer' do
      allow(Rails.logger).to receive(:info)
      token = fresh_token

      expect do
        submit_quick_inquiry({ rendered_at_token: token,
                               PublicFormSpamGate::HONEYPOT_PARAM => 'http://buy-cheap-links.example' })
      end.not_to change(Inquiry, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq('Спасибо! Ваша заявка принята. Мы свяжемся с вами в ближайшее время.')
      expect(flash[:alert]).to be_blank
      expect(Rails.logger).to have_received(:info).with(/reason=honeypot/)
    end

    it 'дропает submit без timestamp рендера (бот не открывал форму)' do
      expect { submit_quick_inquiry }.not_to change(Inquiry, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to be_present
    end

    it 'дропает слишком быструю отправку после рендера' do
      expect { submit_quick_inquiry({ rendered_at_token: PublicFormSpamGate.rendered_at_token }) }
        .not_to change(Inquiry, :count)
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to be_present
    end

    it 'дропает JSON-submit с заблокированным IP: 201 со схемой настоящего успеха, без Inquiry' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
      token = fresh_token

      expect do
        post contact_forms_quick_inquiry_path,
             params: { inquiry: inquiry_params, rendered_at_token: token },
             headers: { 'REMOTE_ADDR' => '80.94.95.173' },
             as: :json
      end.not_to change(Inquiry, :count)

      expect(response).to have_http_status(:created)
      # Блокер 4 из ревью #262: дроп неотличим от успеха — та же схема
      # (ключи и типы), что у легитимного JSON-ответа ниже.
      body = response.parsed_body
      expect(body.keys).to match_array(%w[success message inquiry_id])
      expect(body['success']).to be true
      expect(body['message']).to eq('Заявка принята')
      expect(body['inquiry_id']).to be_an(Integer)
    end

    it 'JSON-дроп и легитимный JSON-успех отдают одну схему ответа' do
      token = fresh_token
      post contact_forms_quick_inquiry_path,
           params: { inquiry: inquiry_params, rendered_at_token: token },
           as: :json
      legit = response.parsed_body

      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
      post contact_forms_quick_inquiry_path,
           params: { inquiry: inquiry_params, rendered_at_token: fresh_token },
           headers: { 'REMOTE_ADDR' => '80.94.95.173' },
           as: :json
      dropped = response.parsed_body

      expect(dropped.keys).to eq(legit.keys)
      expect(dropped['success']).to eq(legit['success'])
      expect(dropped['message']).to eq(legit['message'])
      expect(dropped['inquiry_id']).to be_an(Integer)
    end

    it 'дропает submit из CIDR-подсети блэклиста' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '45.128.232.0/24', source: 'firehol')
      token = fresh_token

      expect do
        post contact_forms_quick_inquiry_path,
             params: { inquiry: inquiry_params, rendered_at_token: token },
             headers: { 'REMOTE_ADDR' => '45.128.232.202' }
      end.not_to change(Inquiry, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to be_present
    end
  end

  describe 'rate limit quick_inquiry' do
    it 'четвёртый сабмит за час с одного IP дропается молча' do
      3.times do
        token = fresh_token
        cookies.delete('visitor_token')
        expect { submit_quick_inquiry({ rendered_at_token: token }) }.to change(Inquiry, :count).by(1)
      end

      token = fresh_token
      cookies.delete('visitor_token')
      expect { submit_quick_inquiry({ rendered_at_token: token }) }.not_to change(Inquiry, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to be_present
      expect(flash[:alert]).to be_blank
      expect(Rails.cache.read(PublicFormSpamGate.counter_key('quick_inquiry', 'rate_limit')).to_i).to eq 1
    end

    it 'не расходует квоту на невалидные сабмиты: три ошибки, затем три успеха' do
      3.times do
        token = fresh_token
        cookies.delete('visitor_token')
        expect do
          post contact_forms_quick_inquiry_path,
               params: { inquiry: inquiry_params.merge(name: ''), rendered_at_token: token },
               as: :json
        end.not_to change(Inquiry, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      3.times do
        token = fresh_token
        cookies.delete('visitor_token')
        expect { submit_quick_inquiry({ rendered_at_token: token }) }.to change(Inquiry, :count).by(1)
      end
    end
  end

  describe 'невалидный сабмит после гейта (блокер 2 из ревью #262)' do
    it 'исправленный повтор с той же visitor-cookie проходит: маркеры освобождены' do
      token = fresh_token
      expect do
        post contact_forms_quick_inquiry_path,
             params: { inquiry: inquiry_params.merge(name: ''), rendered_at_token: token },
             as: :json
      end.not_to change(Inquiry, :count)
      expect(response).to have_http_status(:unprocessable_entity)

      # Повтор с исправленными полями и ТОЙ ЖЕ visitor-cookie: маркер
      # идемпотентности обязан быть освобождён failure-веткой, иначе
      # сабмит был бы молча отброшен как duplicate на 15 минут.
      expect do
        submit_quick_inquiry({ rendered_at_token: fresh_token })
      end.to change(Inquiry, :count).by(1)
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq('Спасибо! Ваша заявка принята. Мы свяжемся с вами в ближайшее время.')
    end
  end

  describe 'POST /contact_forms/consultation — эндпоинт без живой формы' do
    it 'дропает submit без timestamp рендера: нет Inquiry и mailer' do
      expect do
        post contact_forms_consultation_path,
             params: { inquiry: inquiry_params.merge(consultation_type: 'sale', preferred_date: Date.tomorrow) }
      end.not_to change(Inquiry, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq('Заявка на консультацию принята! Мы свяжемся с вами для согласования времени.')
    end

    it 'принимает submit с валидным token — эндпоинт жив, просто под гейтом' do
      expect do
        post contact_forms_consultation_path,
             params: { inquiry: inquiry_params.merge(consultation_type: 'sale', preferred_date: Date.tomorrow),
                       rendered_at_token: fresh_token }
      end.to change(Inquiry, :count).by(1)

      expect(response).to redirect_to(root_path)
    end

    it 'дропает mortgage_application без token' do
      expect do
        post contact_forms_mortgage_application_path,
             params: { inquiry: inquiry_params.merge(property_price: 5_000_000, down_payment: 1_000_000,
                                                     loan_term: 20, monthly_income: 150_000) }
      end.not_to change(Inquiry, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq('Заявка на ипотеку принята! Мы подберем для вас лучшие предложения.')
    end

    it 'дропает property_selection без token' do
      expect do
        post contact_forms_property_selection_path,
             params: { inquiry: inquiry_params.merge(property_type: 'apartment', deal_type: 'sale',
                                                     min_price: 3_000_000, max_price: 7_000_000) }
      end.not_to change(Inquiry, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq('Заявка принята! Мы подберем для вас подходящие варианты и пришлем на email.')
    end

    # Блокер 1 из ревью #262: enum Inquiry не знает 'property_selection' —
    # легитимный сабмит падал ArgumentError до save. Подбор вариантов —
    # заявка агенту: inquiry_type из существующего enum.
    it 'принимает валидный property_selection: Inquiry с inquiry_type из enum и mailer' do
      expect do
        post contact_forms_property_selection_path,
             params: { inquiry: inquiry_params.merge(property_type: 'apartment', deal_type: 'sale',
                                                     min_price: 3_000_000, max_price: 7_000_000),
                       rendered_at_token: fresh_token }
      end.to change(Inquiry, :count).by(1)
        .and have_enqueued_job(ActionMailer::MailDeliveryJob).at_least(:once)

      expect(response).to redirect_to(root_path)
      expect(Inquiry.last.inquiry_type).to eq('contact_agent')
    end

    it 'принимает валидный property_selection по JSON: та же схема успеха, что у дропа' do
      expect do
        post contact_forms_property_selection_path,
             params: { inquiry: inquiry_params.merge(property_type: 'apartment', deal_type: 'sale',
                                                     min_price: 3_000_000, max_price: 7_000_000),
                       rendered_at_token: fresh_token },
             as: :json
      end.to change(Inquiry, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.keys).to match_array(%w[success message matching_count])
      expect(response.parsed_body['matching_count']).to be_an(Integer)
    end

    it 'дропает callback с заблокированного IP: ни Inquiry, ни письма менеджерам' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
      token = fresh_token

      expect do
        post contact_forms_callback_path,
             params: { inquiry: inquiry_params.merge(preferred_time: 'asap'),
                       rendered_at_token: token },
             headers: { 'REMOTE_ADDR' => '80.94.95.173' }
      end.not_to change(Inquiry, :count)

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to eq('Заявка на звонок принята! Мы перезвоним вам в течение 15 минут.')
    end
  end

  describe 'POST /contact_forms/viewing_schedule' do
    let(:property) { create(:property) }

    let(:viewing_params) do
      {
        property_id: property.id,
        viewing_schedule: {
          name: 'Иван Петров', phone: '+79001234567', email: 'ivan@example.com',
          preferred_date: Date.tomorrow, preferred_time: '10:00', message: 'Удобно в выходной'
        }
      }
    end

    # Легитимный сабмит здесь не проверяем: ViewingSchedule валидирует
    # preferred_date/preferred_time, которых нет в схеме viewing_schedules
    # (и user_id NOT NULL при optional :user) — эндпоинт падает 500 на любой
    # попытке сохранения ещё до гейта. Это пре-существующая поломка модели,
    # чинится отдельной задачей; гейт тестируем на дропах — они срабатывают
    # раньше сломанного кода.
    it 'дропает honeypot до ViewingSchedule/Inquiry: redirect на объект с success-нотисом' do
      token = fresh_token
      expect do
        post contact_forms_viewing_schedule_path,
             params: viewing_params.merge(rendered_at_token: token,
                                          PublicFormSpamGate::HONEYPOT_PARAM => 'http://spam.example')
      end.not_to change(ViewingSchedule, :count)
      expect(Inquiry.count).to eq(0)

      expect(response).to redirect_to(property_path(property))
      expect(flash[:notice]).to eq('Запись на показ принята! Мы свяжемся с вами для подтверждения.')
    end

    it 'дропает submit с IP из блэклиста до ViewingSchedule/Inquiry' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
      token = fresh_token

      expect do
        post contact_forms_viewing_schedule_path,
             params: viewing_params.merge(rendered_at_token: token),
             headers: { 'REMOTE_ADDR' => '80.94.95.173' }
      end.not_to change(ViewingSchedule, :count)
      expect(Inquiry.count).to eq(0)

      expect(response).to redirect_to(property_path(property))
      expect(flash[:notice]).to eq('Запись на показ принята! Мы свяжемся с вами для подтверждения.')
    end
  end

  describe 'разметка живых форм' do
    it 'CTA-форма и модалки несут honeypot и подписанный timestamp рендера' do
      %w[
        app/views/home/_cta_form.html.erb
        app/views/external_listings/show.html.erb
        app/views/shared/_callback_modal.html.erb
        app/views/shared/_viewing_schedule_modal.html.erb
      ].each do |partial|
        markup = File.read(Rails.root.join(partial))
        expect(markup).to include('PublicFormSpamGate::HONEYPOT_PARAM'),
                            "нет honeypot в #{partial}"
        expect(markup).to include('rendered_at_token'), "нет render-token в #{partial}"
      end
    end
  end
end
