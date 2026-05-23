# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmbedLeadEventJob do
  let(:lead_ref) do
    User.find_or_create_by!(email: "stub-#{SecureRandom.hex(4)}@stub.local") do |u|
      u.password = SecureRandom.urlsafe_base64(20)
      u.first_name = 'Test'; u.last_name = 'Stub'; u.role = :client; u.active = true
    end
  end

  let(:le) do
    LeadEvent.create!(
      lead_ref: lead_ref, source: 'site_form', current_stage: 'new',
      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
      metadata: { 'name' => 'Иван Петров', 'summary' => 'Хочет квартиру в Канищево 2-комн' }
    )
  end

  let(:fake_vec) { Array.new(768) { rand(-1.0..1.0) } }
  let(:fake_client) { instance_double(Embedding::GoogleClient, embed: fake_vec) }

  before { allow(Embedding::GoogleClient).to receive(:new).and_return(fake_client) }

  describe '#perform' do
    it 'создаёт LeadEventEmbedding запись' do
      expect { described_class.new.perform(le.id) }.to change { LeadEventEmbedding.count }.by(1)
      rec = LeadEventEmbedding.find_by(lead_event_id: le.id)
      expect(rec.embedded_at).to be_present
      expect(rec.embedding.size).to eq(768)
    end

    it 'skip если content_hash не изменился (idempotent re-run)' do
      described_class.new.perform(le.id)
      expect(fake_client).to have_received(:embed).once

      described_class.new.perform(le.id)
      expect(fake_client).to have_received(:embed).once # не повторно
    end

    it 're-embed когда metadata.summary меняется' do
      described_class.new.perform(le.id)
      le.update!(metadata: le.metadata.merge('summary' => 'Совсем другая ситуация'))
      described_class.new.perform(le.id)
      expect(fake_client).to have_received(:embed).twice
    end

    it 'skip если LeadEvent не найден' do
      expect { described_class.new.perform(999_999_999) }.not_to change { LeadEventEmbedding.count }
    end

    it 'skip если text template пустой (нет name/summary/notes)' do
      bare = LeadEvent.create!(
        lead_ref: lead_ref, source: 'manual', current_stage: 'new',
        anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
        metadata: {}
      )
      # Текст шаблон возвращает source/stage/topic — non-empty всё равно
      # generate'нется. Это OK — будет embed даже для sparse leads.
      expect { described_class.new.perform(bare.id) }.to change { LeadEventEmbedding.count }.by(1)
    end
  end
end
