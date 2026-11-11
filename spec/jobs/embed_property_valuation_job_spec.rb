# frozen_string_literal: true

require 'rails_helper'
require 'rake'

RSpec.describe EmbedPropertyValuationJob do
  let(:fake_vec) { Array.new(768) { rand(-1.0..1.0) } }
  let(:fake_client) { instance_double(Embedding::GoogleClient, embed: fake_vec) }

  before do
    allow(Embedding::GoogleClient).to receive(:new).and_return(fake_client)
    Thread.current[:skip_workbot_push] = true
  end

  after { Thread.current[:skip_workbot_push] = nil }

  let!(:valuation) do
    PropertyValuation.create!(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      status: 'completed',
      address: 'г. Рязань, ул. Праволыбедская, д. 24',
      city: 'Рязань', district: 'Железнодорожный',
      latitude: 54.6292, longitude: 39.7417,
      total_area: 44.0, rooms: 2, floor: 4, total_floors: 5,
      estimated_price: 4_400_000,
      evaluation_data: { 'comparables' => [{ 'price' => 1 }] }
    )
  end

  describe '#perform' do
    it 'создаёт PropertyValuationEmbedding запись' do
      expect { described_class.new.perform(valuation.id) }
        .to change { PropertyValuationEmbedding.count }.by(1)

      rec = PropertyValuationEmbedding.find_by!(property_valuation_id: valuation.id)
      expect(rec.embedded_at).to be_present
      expect(rec.embedding.size).to eq(768)
      expect(rec.content_hash).to be_present
      expect(rec.content_text).to include('Рязань')
    end

    it 'skip если content_hash не изменился (idempotent re-run, без вызова GoogleClient)' do
      described_class.new.perform(valuation.id)
      expect(fake_client).to have_received(:embed).once

      described_class.new.perform(valuation.id)
      expect(fake_client).to have_received(:embed).once # не повторно
    end

    it 're-embed когда параметры оценки меняются' do
      described_class.new.perform(valuation.id)
      valuation.update!(estimated_price: 5_100_000)
      described_class.new.perform(valuation.id)
      expect(fake_client).to have_received(:embed).twice
    end

    it 'skip если valuation не найдена' do
      expect { described_class.new.perform(999_999_999) }
        .not_to change { PropertyValuationEmbedding.count }
    end

    it 'skip если valuation не в статусе completed' do
      pending_valuation = PropertyValuation.create!(
        property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
        status: 'pending',
        address: 'г. Рязань, ул. Праволыбедская, д. 25',
        latitude: 54.6292, longitude: 39.7417,
        total_area: 40.0
      )

      expect { described_class.new.perform(pending_valuation.id) }
        .not_to change { PropertyValuationEmbedding.count }
      expect(fake_client).not_to have_received(:embed)
    end

    it 'поднимает ошибку записи — бэкфилл embeddings:valuations учтёт её в failed' do
      allow(PropertyValuationEmbedding).to receive(:find_or_initialize_by)
        .and_raise(ActiveRecord::ConnectionNotEstablished)

      expect { described_class.new.perform(valuation.id) }
        .to raise_error(ActiveRecord::ConnectionNotEstablished)
    end
  end

  describe 'trigger — PropertyValuation after_commit' do
    it 'переход в completed ставит job в очередь' do
      pending_valuation = PropertyValuation.create!(
        property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
        status: 'pending',
        address: 'г. Рязань, ул. Праволыбедская, д. 26',
        latitude: 54.6292, longitude: 39.7417,
        total_area: 41.0
      )

      expect do
        pending_valuation.update!(status: 'completed', estimated_price: 4_100_000)
      end.to have_enqueued_job(described_class).with(pending_valuation.id)
    end

    it 'переход в failed НЕ ставит job в очередь' do
      expect do
        valuation.update!(status: 'failed')
      end.not_to have_enqueued_job(described_class)
    end

    it 'update без смены статуса НЕ ставит job в очередь повторно' do
      expect do
        valuation.update!(views_count: 3)
      end.not_to have_enqueued_job(described_class)
    end
  end

  describe 'rake embeddings:valuations' do
    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('embeddings:valuations')
      Rake::Task['embeddings:valuations'].reenable
      allow(Kernel).to receive(:sleep)
      allow_any_instance_of(Object).to receive(:sleep)
    end

    it 'считает сбой в failed и не ставит асинхронный retry' do
      allow(fake_client).to receive(:embed).and_raise(Embedding::GoogleClient::Error, 'rate limit')

      expect do
        expect do
          Rake::Task['embeddings:valuations'].invoke
        end.to output(/done=0 failed=1/).to_stdout
          .and output(/failed: Embedding::GoogleClient::Error/).to_stderr
      end.not_to have_enqueued_job(described_class)
    end
  end
end
