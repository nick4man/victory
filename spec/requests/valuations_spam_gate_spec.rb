# frozen_string_literal: true

require 'rails_helper'

# Антиспам-гейт оценок (issue #262, часть 2): express /sell/valuation и
# investment /valuations/audit. Гейт срабатывает ДО PropertyValuationJob /
# InvestmentAuditJob — заблокированный submit не запускает LLM-цепочку
# (~$0.25-0.40 за прогон). Существующие Redis-лимиты (5/час) не ужесточены:
# собственный счётчик гейта для оценок выключен (rate_limit: 0).
RSpec.describe 'Антиспам-гейт оценок', type: :request do
  around do |example|
    old = ENV.fetch('TG_WORK_BOT_DISABLED', nil)
    ENV['TG_WORK_BOT_DISABLED'] = 'true'
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    # Существующие Redis-лимиты оценок (valuation_express/investment_audit)
    # живут в настоящем Redis и переживают прогон — чистим ключи, иначе
    # повторные запуски спека упираются в лимит 5/час на тестовых IP.
    redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/1'))
    %w[valuation_express:submit:* investment_audit:submit:*].each do |pattern|
      redis.scan_each(match: pattern) { |key| redis.del(key) }
    end
    example.run
    Rails.cache = original_cache
    old.nil? ? ENV.delete('TG_WORK_BOT_DISABLED') : ENV['TG_WORK_BOT_DISABLED'] = old
    travel_back
  end

  before do
    # Геокодинг адреса в PropertyValuation#resolve_coordinates — внешний HTTP.
    allow(Geocoding::AddressLookup).to receive(:call).and_return(nil)
  end

  # Токен минтится ДО travel: иначе rendered_at свежее MIN_FILL_SECONDS
  # и гейт дропает сабмит как too_fast.
  def fresh_token
    token = PublicFormSpamGate.rendered_at_token
    travel 5.seconds
    token
  end

  let(:express_params) do
    {
      property_valuation: {
        property_type: 'apartment', deal_type: 'sale',
        address: 'Рязань, ул. Тестовая, д. 1, кв. 10',
        total_area: 54, rooms: 2,
        name: 'Иван Петров', phone: '+79001234567', email: 'ivan@example.com'
      }
    }
  end

  let(:investment_params) do
    {
      property_valuation: {
        property_type: 'apartment', deal_type: 'sale',
        address: 'Рязань, ул. Тестовая, д. 1, кв. 10',
        total_area: 54, rooms: 2, estimated_price: 5_000_000,
        name: 'Иван Петров', phone: '+79001234567'
      }
    }
  end

  describe 'GET /valuations/new — разметка формы' do
    it 'несёт honeypot и подписанный timestamp рендера' do
      get new_property_valuation_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(PublicFormSpamGate::HONEYPOT_PARAM.to_s)
      expect(response.body).to include('rendered_at_token')
    end
  end

  describe 'POST /valuations (express)' do
    def submit_express(extra = {}, ip: nil)
      headers = ip ? { 'REMOTE_ADDR' => ip } : {}
      post property_valuations_path, params: express_params.merge(extra), headers: headers
    end

    it 'нормальный сабмит создаёт оценку и ставит PropertyValuationJob' do
      expect { submit_express({ rendered_at_token: fresh_token }, ip: '203.0.113.11') }
        .to change(PropertyValuation, :count).by(1)
        .and have_enqueued_job(PropertyValuationJob)
    end

    it 'дропает honeypot до LLM-цепочки: нет записи и нет job' do
      token = fresh_token
      expect do
        expect do
          submit_express({ rendered_at_token: token,
                           PublicFormSpamGate::HONEYPOT_PARAM => 'http://buy-cheap-links.example' },
                         ip: '203.0.113.12')
        end.not_to change(PropertyValuation, :count)
      end.not_to have_enqueued_job(PropertyValuationJob)

      expect(response).to redirect_to(new_property_valuation_path)
      expect(flash[:notice]).to be_present
      expect(flash[:alert]).to be_blank
    end

    it 'дропает submit с IP из блэклиста до LLM-цепочки' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
      token = fresh_token

      expect do
        expect { submit_express({ rendered_at_token: token }, ip: '80.94.95.173') }
          .not_to change(PropertyValuation, :count)
      end.not_to have_enqueued_job(PropertyValuationJob)

      expect(response).to redirect_to(new_property_valuation_path)
      expect(flash[:notice]).to be_present
    end

    it 'дропает submit из CIDR-подсети блэклиста' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '45.128.232.0/24', source: 'firehol')
      token = fresh_token

      expect do
        expect { submit_express({ rendered_at_token: token }, ip: '45.128.232.202') }
          .not_to change(PropertyValuation, :count)
      end.not_to have_enqueued_job(PropertyValuationJob)
    end

    it 'дропает submit без timestamp рендера (бот не открывал форму)' do
      expect do
        expect { submit_express(ip: '203.0.113.13') }.not_to change(PropertyValuation, :count)
      end.not_to have_enqueued_job(PropertyValuationJob)
    end

    it 'не ужесточает лимиты для чистых IP: 4 сабмита подряд проходят гейт' do
      4.times do |i|
        token = fresh_token
        expect { submit_express({ rendered_at_token: token }, ip: '203.0.113.14') }
          .to change(PropertyValuation, :count).by(1), "сабмит ##{i + 1} должен пройти"
      end
    end
  end

  describe 'GET /valuations/audit/new — разметка формы' do
    it 'несёт honeypot и подписанный timestamp рендера' do
      allow(MacroRatesService).to receive(:call).and_return(
        { key_rate: 16.5, mortgage_rate: 18.5, deposit_rate: 15.5, effective_date: '2026-11-25', stale: false }
      )

      get investment_audit_new_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(PublicFormSpamGate::HONEYPOT_PARAM.to_s)
      expect(response.body).to include('rendered_at_token')
    end
  end

  describe 'POST /valuations/audit (investment)' do
    def submit_investment(extra = {}, ip: nil)
      headers = ip ? { 'REMOTE_ADDR' => ip } : {}
      post investment_audit_create_path, params: investment_params.merge(extra), headers: headers
    end

    it 'нормальный сабмит создаёт аудит и ставит InvestmentAuditJob' do
      expect { submit_investment({ rendered_at_token: fresh_token }, ip: '203.0.113.21') }
        .to change(PropertyValuation, :count).by(1)
        .and have_enqueued_job(InvestmentAuditJob)

      expect(PropertyValuation.order(:id).last.audit_mode).to eq('investment')
    end

    it 'дропает honeypot до LLM-цепочки: нет записи и нет job' do
      token = fresh_token
      expect do
        expect do
          submit_investment({ rendered_at_token: token,
                              PublicFormSpamGate::HONEYPOT_PARAM => 'http://buy-cheap-links.example' },
                            ip: '203.0.113.22')
        end.not_to change(PropertyValuation, :count)
      end.not_to have_enqueued_job(InvestmentAuditJob)

      expect(response).to redirect_to(investment_audit_new_path)
      expect(flash[:notice]).to be_present
    end

    it 'дропает submit с IP из блэклиста до LLM-цепочки' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
      token = fresh_token

      expect do
        expect { submit_investment({ rendered_at_token: token }, ip: '80.94.95.173') }
          .not_to change(PropertyValuation, :count)
      end.not_to have_enqueued_job(InvestmentAuditJob)

      expect(response).to redirect_to(investment_audit_new_path)
      expect(flash[:notice]).to be_present
    end

    it 'дропает submit без timestamp рендера' do
      expect do
        expect { submit_investment(ip: '203.0.113.23') }.not_to change(PropertyValuation, :count)
      end.not_to have_enqueued_job(InvestmentAuditJob)
    end

    it 'не ужесточает лимиты для чистых IP: 4 сабмита подряд проходят гейт' do
      4.times do |i|
        token = fresh_token
        expect { submit_investment({ rendered_at_token: token }, ip: '203.0.113.24') }
          .to change(PropertyValuation, :count).by(1), "сабмит ##{i + 1} должен пройти"
      end
    end
  end
end
