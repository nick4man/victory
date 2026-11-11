# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::RequestSpecialistEvaluation do
  let(:tg_client) { instance_double(Telegram::Client) }
  let(:sent_messages) { [] }

  before do
    allow(Telegram::Client).to receive(:new).and_return(tg_client)
    allow(tg_client).to receive(:send_message) do |text, opts|
      sent_messages << [text, opts]
      { 'message_id' => 555 }
    end
  end

  def call_tool(extra = {})
    described_class.call({ 'name' => 'Анна', 'phone' => '+79001234567' }.merge(extra))
  end

  describe 'с valuation_token завершённой оценки' do
    let!(:valuation) do
      PropertyValuation.create!(
        property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
        status: 'completed',
        address: 'г. Рязань, ул. Праволыбедская, д. 24', city: 'Рязань',
        latitude: 54.6292, longitude: 39.7417,
        total_area: 54.0, rooms: 2,
        estimated_price: 5_400_000,
        # token генерирует колбэк generate_token — берём valuation.token
        evaluation_data: {
          'similar_valuations' => {
            'count' => 5, 'median_price' => 5_100_000,
            'min_price' => 4_800_000, 'max_price' => 5_500_000,
            'low_coverage' => false
          }
        }
      )
    end

    it 'создаёт Inquiry типа evaluation с ориентировкой в данных лида' do
      expect { call_tool('valuation_token' => valuation.token) }
        .to change(Inquiry, :count).by(1)

      inquiry = Inquiry.order(:created_at).last
      expect(inquiry.inquiry_type).to eq('evaluation')
      expect(inquiry.source).to eq('site_chatbot')
      expect(inquiry.name).to eq('Анна')
      expect(inquiry.phone).to eq('79001234567') # Inquiry нормализует phone (normalize_phone)
      expect(inquiry.message).to include('5 100 000')
      expect(inquiry.message).to match(/оценкам наших специалистов/)
      expect(inquiry.metadata['similar_valuations']['count']).to eq(5)
      expect(inquiry.metadata['property_valuation_token']).to eq(valuation.token)
    end

    it 'LeadAnnouncer публикует карточку в топик #ОЦЕНКА (auto_route site_valuation)' do
      expect { call_tool('valuation_token' => valuation.token) }
        .to change(LeadEvent, :count).by(1) # ровно одна карточка на лид

      lead = LeadEvent.order(:id).last
      expect(lead.source).to eq('site_valuation')
      expect(lead.anchor_topic_key).to eq('appraisal')
      expect(lead.lead_ref).to eq(valuation)

      card_text, card_opts = sent_messages.last
      expect(card_opts[:message_thread_id]).to eq(24) # #ОЦЕНКА в config/telegram_topics.yml
      # в карточке — ориентир по похожим оценкам и результаты экспресс-оценки
      expect(card_text).to include('5 100 000')
      expect(card_text).to include('5 400 000')
      expect(card_text).to include('Анна')
    end

    it 'только valuation_token без параметров объекта → объект подставляется из оценки (fallback)' do
      res = call_tool('valuation_token' => valuation.token)

      inquiry = Inquiry.order(:created_at).last
      expect(inquiry.message).to include('Праволыбедская')
      expect(inquiry.message).to include('54 м²')
      expect(res[:success]).to be(true)
    end

    it 'fallback для участка показывает площадь в сотках из land_area (ревью #206)' do
      valuation.update_columns(
        property_type: 'land',
        total_area: 800.0,   # нормализация EstimatePropertyValuation: сотки × 100
        land_area: 8.0
      )

      call_tool('valuation_token' => valuation.token)

      inquiry = Inquiry.order(:created_at).last
      expect(inquiry.message).to include('8 сот.')
      expect(inquiry.message).not_to include('800 м²')
    end

    it 'участок: LLM продублировала total_area в сотках при token — не показываем как м² (нит-пик ревью #206)' do
      valuation.update_columns(
        property_type: 'land',
        total_area: 800.0,
        land_area: 8.0
      )

      call_tool('valuation_token' => valuation.token, 'total_area' => 8)

      inquiry = Inquiry.order(:created_at).last
      expect(inquiry.message).to include('8 сот.')
      expect(inquiry.message).not_to include('8 м²')
      expect(inquiry.message).not_to include('800 м²')
    end

    it 'похожих оценок мало (N < 3) → честный ориентир по экспресс-оценке с указанием найденного' do
      valuation.update_columns(
        evaluation_data: { 'similar_valuations' => { 'count' => 1, 'median_price' => nil,
                                                     'min_price' => nil, 'max_price' => nil,
                                                     'low_coverage' => true } }
      )

      res = call_tool('valuation_token' => valuation.token)

      inquiry = Inquiry.order(:created_at).last
      expect(inquiry.message).to match(/Похожих оценок мало/)
      expect(inquiry.message).to match(/найдено: 1/)
      expect(inquiry.message).to include('5 400 000')
      expect(res[:orientation]).to match(/экспресс-оценке/)
    end

    it 'инфраструктурный сбой поиска (evaluation_data без similar_valuations) → нейтральный экспресс-ориентир без «найдено: N»' do
      valuation.update_columns(evaluation_data: {})

      res = call_tool('valuation_token' => valuation.token)

      inquiry = Inquiry.order(:created_at).last
      expect(inquiry.message).to match(/Ориентир по экспресс-оценке/)
      expect(inquiry.message).to include('5 400 000')
      expect(inquiry.message).not_to match(/найдено/)
      expect(inquiry.metadata['similar_valuations']).to be_nil
      expect(res[:orientation]).to match(/экспресс-оценке/)
      expect(res[:orientation]).not_to match(/найдено/)
    end
  end

  describe 'без valuation_token' do
    it 'создаёт лид с параметрами объекта из аргументов' do
      expect do
        call_tool('property_type' => 'apartment', 'city' => 'Рязань',
                  'address' => 'г. Рязань, ул. Тестовая, д. 1', 'total_area' => 54, 'rooms' => 2)
      end.to change(Inquiry, :count).by(1)

      inquiry = Inquiry.order(:created_at).last
      expect(inquiry.inquiry_type).to eq('evaluation')
      expect(inquiry.message).to include('Тестовая')
      expect(inquiry.metadata['similar_valuations']).to be_nil
    end
  end

  describe 'сквозной путь: оценка через чат-тул → передача специалисту' do
    let(:service_result) do
      {
        success: true,
        estimated_price: 5_400_000, min_price: 4_968_000, max_price: 5_832_000,
        price_per_sqm: 100_000, confidence_level: 0.65, tier: 4,
        comparables: [], ai_summary: '', low_coverage: false
      }
    end

    before do
      allow(PropertyEvaluationService).to receive(:new).and_return(double(call: service_result))
      allow(Geocoding::AddressLookup).to receive(:call).and_return(nil)
      allow(Valuations::SimilarValuationsFinder).to receive(:call).and_return(nil)
    end

    it 'создаёт ровно один LeadEvent и одну TG-карточку суммарно (ревью #206)' do
      res = ChatTools::EstimatePropertyValuation.call(
        'property_type' => 'apartment',
        'address' => 'г. Рязань, ул. Тестовая, д. 1',
        'city' => 'Рязань',
        'total_area' => 54
      )
      expect(res[:success]).to be(true)

      expect do
        call_tool('valuation_token' => res[:token])
      end.to change(LeadEvent, :count).by(1)
      expect(sent_messages.size).to eq(1)

      lead = LeadEvent.order(:id).last
      expect(lead.lead_ref_type).to eq('PropertyValuation')
      expect(lead.anchor_topic_key).to eq('appraisal')
    end
  end

  describe 'валидация и идемпотентность' do
    it 'без имени/телефона → missing_fields, Inquiry не создан' do
      expect { described_class.call('phone' => '+79001234567') }
        .not_to change(Inquiry, :count)

      res = described_class.call('phone' => '+79001234567')
      expect(res[:error]).to eq('missing_fields')
      expect(res[:missing]).to eq(['name'])
    end

    it 'повторный вызов с тем же телефоном в течение 5 минут не плодит дубль' do
      call_tool
      expect { call_tool }.not_to change(Inquiry, :count)

      res = call_tool
      expect(res[:duplicate]).to be(true)
      expect(res[:inquiry_id]).to eq(Inquiry.order(:created_at).last.id)
    end
  end

  describe '.schema' do
    it 'требует явного согласия и имени с телефоном' do
      description = described_class.schema.dig(:function, :description)

      expect(description).to match(/согласил/i)
      expect(described_class.schema.dig(:function, :parameters, :required)).to eq(%w[name phone])
    end
  end
end
