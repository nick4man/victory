# frozen_string_literal: true

require 'rails_helper'

# Антиспам-гейт POST /reviews (issue #261): honeypot + IP-блэклист +
# тайминг + rate limit + идемпотентность по visitor_token. Дроп всегда
# молчаливый — success-ответ без записи и без пинга модерации (образец #255).
RSpec.describe 'Reviews POST /reviews', type: :request do
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

  let(:valid_review_params) do
    {
      author_name: 'Иван Петров',
      author_email: 'ivan@example.com',
      rating: 5,
      title: 'Отличная работа',
      body: 'Продали квартиру за две недели, всё честно и прозрачно.'
    }
  end

  def rendered_at_token_from_page
    response.parsed_body.at_css('input[name="rendered_at_token"]')&.[]('value')
  end

  def honeypot_input_present?
    response.parsed_body.at_css("input[name='#{PublicFormSpamGate::HONEYPOT_PARAM}']").present?
  end

  def submit_review(extra_params = {})
    post reviews_path, params: { review: valid_review_params }.merge(extra_params)
  end

  describe 'GET /reviews/new — разметка формы' do
    it 'содержит honeypot-поле и подписанный timestamp рендера' do
      get new_review_path
      expect(response).to have_http_status(:ok)
      expect(honeypot_input_present?).to be true
      expect(rendered_at_token_from_page).to be_present
    end
  end

  describe 'POST /reviews — нормальный сабмит' do
    it 'создаёт одну запись Review со статусом pending и шлёт один пинг' do
      get new_review_path
      token = rendered_at_token_from_page
      travel 5.seconds

      allow(ReviewModerationNotifier).to receive(:notify)

      expect { submit_review(rendered_at_token: token) }.to change(Review, :count).by(1)

      review = Review.order(:id).last
      expect(review.status_pending?).to be true
      expect(review.source).to eq 'own'
      expect(review.submitted_via).to eq 'web_form'
      expect(ReviewModerationNotifier).to have_received(:notify).once
      expect(response).to redirect_to(reviews_path)
      expect(flash[:notice]).to be_present
    end
  end

  describe 'молчаливый дроп (образец #255) — бот не должен узнать, что раскрыт' do
    it 'дропает заполненный honeypot: success-флэш, без записи и пинга, с логом reason' do
      get new_review_path
      token = rendered_at_token_from_page
      travel 5.seconds

      allow(ReviewModerationNotifier).to receive(:notify)
      allow(Rails.logger).to receive(:info)

      expect do
        submit_review(rendered_at_token: token,
                      PublicFormSpamGate::HONEYPOT_PARAM => 'http://buy-cheap-links.example')
      end.not_to change(Review, :count)

      expect(ReviewModerationNotifier).not_to have_received(:notify)
      expect(response).to redirect_to(reviews_path)
      expect(flash[:notice]).to be_present
      expect(flash[:alert]).to be_blank
      # Блокер #1 из ревью: record должен видеть reason мемоизированного гейта.
      expect(Rails.logger).to have_received(:info).with(/reason=honeypot/)
      expect(Rails.cache.read(PublicFormSpamGate.counter_key('review', 'honeypot')).to_i).to eq 1
    end

    it 'дропает POST без timestamp рендера (бот не открывал форму)' do
      allow(ReviewModerationNotifier).to receive(:notify)

      expect { submit_review }.not_to change(Review, :count)

      expect(ReviewModerationNotifier).not_to have_received(:notify)
      expect(response).to redirect_to(reviews_path)
      expect(flash[:notice]).to be_present
    end

    it 'дропает отправку быстрее MIN_FILL_SECONDS после рендера' do
      get new_review_path
      token = rendered_at_token_from_page

      expect { submit_review(rendered_at_token: token) }.not_to change(Review, :count)
      expect(response).to redirect_to(reviews_path)
      expect(flash[:notice]).to be_present
    end

    it 'счётчик IP-дропа растёт для реальных дропов (мемоизированный гейт)' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
      get new_review_path
      token = rendered_at_token_from_page
      travel 5.seconds

      post reviews_path,
           params: { review: valid_review_params }.merge(rendered_at_token: token),
           headers: { 'REMOTE_ADDR' => '80.94.95.173' }

      expect(response).to redirect_to(reviews_path)
      expect(Rails.cache.read(PublicFormSpamGate.counter_key('review', 'spam_ip')).to_i).to eq 1
    end

    context 'с IP из блэклиста SpamBlockedEntry' do
      let(:blocked_ip) { '80.94.95.173' }

      before do
        SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: blocked_ip, source: 'firehol')
      end

      it 'дропает submit с заблокированным IP (точное совпадение)' do
        get new_review_path
        token = rendered_at_token_from_page
        travel 5.seconds

        expect do
          submit_review(rendered_at_token: token)
          # headers REMOTE_ADDR задаётся ниже в отдельном прогоне
        end.to change(Review, :count).by(1)

        # Теперь с заблокированным IP — молчаливый дроп.
        get new_review_path
        token = rendered_at_token_from_page
        travel 5.seconds
        expect do
          post reviews_path,
               params: { review: valid_review_params.merge(body: 'Второй отзыв с другого IP.') }
                              .merge(rendered_at_token: token),
               headers: { 'REMOTE_ADDR' => blocked_ip }
        end.not_to change(Review, :count)
        expect(response).to redirect_to(reviews_path)
        expect(flash[:notice]).to be_present
      end

      it 'дропает submit из CIDR-подсети блэклиста' do
        SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '45.128.232.0/24', source: 'firehol')
        get new_review_path
        token = rendered_at_token_from_page
        travel 5.seconds

        expect do
          post reviews_path,
               params: { review: valid_review_params }.merge(rendered_at_token: token),
               headers: { 'REMOTE_ADDR' => '45.128.232.202' }
        end.not_to change(Review, :count)
        expect(response).to redirect_to(reviews_path)
      end
    end
  end

  describe 'идемпотентность по visitor_token (кейс двойного сабмита)' do
    it 'двойной сабмит даёт одну запись и один пинг' do
      get new_review_path
      token = rendered_at_token_from_page
      travel 5.seconds

      allow(ReviewModerationNotifier).to receive(:notify)

      expect { submit_review(rendered_at_token: token) }.to change(Review, :count).by(1)
      # Дубль: новый токен рендера (второй «клик»), тот же visitor_token cookie.
      travel 5.seconds
      expect { submit_review(rendered_at_token: PublicFormSpamGate.rendered_at_token) }
        .not_to change(Review, :count)

      expect(ReviewModerationNotifier).to have_received(:notify).once
      expect(response).to redirect_to(reviews_path)
      expect(flash[:notice]).to be_present
    end

    it 'другой visitor_token проходит как независимый сабмит' do
      get new_review_path
      token = rendered_at_token_from_page
      travel 5.seconds

      expect { submit_review(rendered_at_token: token) }.to change(Review, :count).by(1)

      cookies.delete('visitor_token')
      get new_review_path
      token2 = rendered_at_token_from_page
      travel 5.seconds

      expect { submit_review(rendered_at_token: token2) }.to change(Review, :count).by(1)
    end
  end

  describe 'rate limit' do
    it 'четвёртый сабмит за час с одного IP дропается молча' do
      3.times do
        get new_review_path
        token = rendered_at_token_from_page
        travel 5.seconds
        # Разные visitor_token: каждый сабмит — «новый» клиент, чтобы
        # идемпотентность не схлопывала их раньше rate limit.
        cookies.delete('visitor_token')
        submit_review(rendered_at_token: token)
        expect(response).to redirect_to(reviews_path)
      end

      get new_review_path
      token = rendered_at_token_from_page
      travel 5.seconds
      cookies.delete('visitor_token')
      expect { submit_review(rendered_at_token: token) }.not_to change(Review, :count)
      expect(response).to redirect_to(reviews_path)
      expect(flash[:notice]).to be_present
      expect(flash[:alert]).to be_blank
      # Нит-пик из ревью: дроп именно по rate_limit, не за счёт дубля.
      expect(Rails.cache.read(PublicFormSpamGate.counter_key('review', 'rate_limit')).to_i).to eq 1
    end

    it 'счётчик не расходуется невалидными сабмитами' do
      3.times do
        submit_review(rendered_at_token: 'tampered')
      end

      get new_review_path
      token = rendered_at_token_from_page
      travel 5.seconds
      expect { submit_review(rendered_at_token: token) }.to change(Review, :count).by(1)
    end
  end

  describe 'невалидный отзыв после гейта' do
    it 'перерисовывает форму с ошибками и свежим timestamp' do
      get new_review_path
      token = rendered_at_token_from_page
      travel 5.seconds

      submit_review(rendered_at_token: token, review: valid_review_params.merge(body: 'коротко'))
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('Не удалось сохранить отзыв')
      expect(rendered_at_token_from_page).to be_present
    end

    it 'исправленный повтор после невалидного сабмита проходит целиком (блокер #2 из ревью)' do
      get new_review_path
      token = rendered_at_token_from_page
      travel 5.seconds

      allow(ReviewModerationNotifier).to receive(:notify)

      # Невалидный сабмит прошёл гейт, но не сохранился: маркер идемпотентности
      # обязан освободиться, иначе исправление потеряется на 15 минут.
      submit_review(rendered_at_token: token, review: valid_review_params.merge(body: 'коротко'))
      expect(response).to have_http_status(:unprocessable_content)

      # Форма перерисована со свежим timestamp; тот же visitor_token cookie.
      travel 5.seconds
      corrected_token = rendered_at_token_from_page

      expect { submit_review(rendered_at_token: corrected_token) }.to change(Review, :count).by(1)
      expect(ReviewModerationNotifier).to have_received(:notify).once
      expect(response).to redirect_to(reviews_path)
      expect(flash[:notice]).to be_present

      # Дубль исправленного всё ещё схлопывается идемпотентностью.
      travel 5.seconds
      expect { submit_review(rendered_at_token: PublicFormSpamGate.rendered_at_token) }
        .not_to change(Review, :count)
      expect(ReviewModerationNotifier).to have_received(:notify).once
    end
  end
end
