# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmbedTelegramGroupMessageJob do
  let(:msg) do
    TelegramGroupMessage.create!(
      tg_chat_id: -1_003_779_115_845, tg_message_id: 9999, tg_thread_id: 17,
      tg_user_id: 1, sender_username: 'oks', sender_first_name: 'Оксана',
      body: 'Квартира 3-комн в Канищево, готова к показу',
      payload_kind: 'text', has_attachment: false, sent_at: Time.current
    )
  end

  let(:fake_vec) { Array.new(768) { rand(-1.0..1.0) } }
  let(:fake_client) { instance_double(Embedding::GoogleClient, embed: fake_vec) }

  before { allow(Embedding::GoogleClient).to receive(:new).and_return(fake_client) }

  describe '#perform' do
    it 'создаёт TelegramGroupMessageEmbedding запись' do
      expect { described_class.new.perform(msg.id) }.to change { TelegramGroupMessageEmbedding.count }.by(1)
      rec = TelegramGroupMessageEmbedding.find_by(telegram_group_message_id: msg.id)
      expect(rec.embedded_at).to be_present
      expect(rec.content_hash).to be_present
      expect(rec.embedding.size).to eq(768)
    end

    it 'skip если content_hash не изменился (re-run idempotent)' do
      described_class.new.perform(msg.id)
      expect(fake_client).to have_received(:embed).once

      described_class.new.perform(msg.id) # 2-й запуск — должен skip
      expect(fake_client).to have_received(:embed).once # не вызывается повторно
    end

    it 're-embed если body изменился' do
      described_class.new.perform(msg.id)
      msg.update!(body: 'Совсем другой контент про дом в Солотче')
      described_class.new.perform(msg.id)
      expect(fake_client).to have_received(:embed).twice
    end

    it 'skip если message не найден' do
      expect { described_class.new.perform(999_999_999) }.not_to change { TelegramGroupMessageEmbedding.count }
    end

    it 'skip если body пустой' do
      empty_msg = TelegramGroupMessage.create!(
        tg_chat_id: -1_003_779_115_845, tg_message_id: 9998, tg_thread_id: 17,
        tg_user_id: 2, sender_username: 'x', sender_first_name: 'X',
        body: '', payload_kind: 'photo', has_attachment: true, sent_at: Time.current
      )
      expect { described_class.new.perform(empty_msg.id) }.not_to change { TelegramGroupMessageEmbedding.count }
    end
  end
end
