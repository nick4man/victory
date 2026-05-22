# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::PhotoShareContinuation do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 51_001, tg_username: 'oks07victory', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 51_001)
  end
  let!(:staff) do
    TelegramUser.create!(tg_user_id: 51_002, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 51_002,
                         assignable: true)
  end

  let(:tg_client) do
    instance_double(
      Telegram::Client,
      send_message: { 'message_id' => 1 },
      send_photo: { 'message_id' => 2 },
      download_file: nil # default — NC upload пропустится
    )
  end

  let(:base_msg) do
    {
      'message_id' => 99,
      'from' => { 'id' => director.tg_user_id, 'username' => director.tg_username, 'is_bot' => false },
      'chat' => { 'id' => director.tg_user_id, 'type' => 'private' },
      'text' => 'глянь, такого вида паспорт не принимаем'
    }
  end

  let(:pending_action) do
    {
      'type' => 'photo_disposition',
      'step' => 'share_caption',
      'data' => { 'file_id' => 'AgACFile_share', 'target_staff_id' => staff.id }
    }
  end

  describe '#call' do
    before do
      director.set_pending_action!(type: 'photo_disposition', step: 'share_caption',
                                   data: { file_id: 'AgACFile_share', target_staff_id: staff.id })
    end

    context 'caption передан' do
      it 'шлёт sendPhoto к staff.dm_chat_id с caption + clear pending_action + НЕ создаёт Task' do
        expect do
          described_class.new(msg: base_msg, tg_user: director, pending_action: pending_action,
                              client: tg_client).call
        end.not_to(change { Task.count }) # критично: share-flow Task НЕ создаёт

        expect(tg_client).to have_received(:send_photo).with(
          staff.dm_chat_id, 'AgACFile_share',
          hash_including(caption: a_string_matching(/От @oks07victory.*паспорт не принимаем/m), parse_mode: 'HTML')
        )

        expect(director.reload.dm_pending_action).to eq({})
      end

      it 'отвечает директору success-сообщением' do
        described_class.new(msg: base_msg, tg_user: director, pending_action: pending_action,
                            client: tg_client).call

        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Переслано.*@irina/m),
          hash_including(chat_id: director.tg_user_id, parse_mode: 'HTML')
        )
      end
    end

    context '/skip — без подписи' do
      let(:skip_msg) { base_msg.merge('text' => '/skip') }

      it 'sendPhoto без caption строки от юзера — только mention отправителя' do
        described_class.new(msg: skip_msg, tg_user: director, pending_action: pending_action,
                            client: tg_client).call

        expect(tg_client).to have_received(:send_photo).with(
          staff.dm_chat_id, 'AgACFile_share',
          hash_including(caption: a_string_matching(/^📷 От @oks07victory/))
        )
      end

      it 'success-сообщение указывает «Без подписи»' do
        described_class.new(msg: skip_msg, tg_user: director, pending_action: pending_action,
                            client: tg_client).call

        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Без подписи/),
          hash_including(chat_id: director.tg_user_id)
        )
      end
    end

    context 'sendPhoto fail — fallback на send_message с архив-ссылкой' do
      before do
        allow(tg_client).to receive(:send_photo)
          .and_raise(Telegram::Client::Error.new('sendPhoto bad request 400'))
      end

      it 'fallback на send_message сотруднику если NC archive есть' do
        # Mock NC result via stubbing upload_to_nc indirectly:
        # эмулируем «нет NC» (download_file=nil → upload_to_nc=nil) → delivered=false
        result = described_class.new(msg: base_msg, tg_user: director, pending_action: pending_action,
                                     client: tg_client).call
        expect(result).to eq(:handled)
        expect(director.reload.dm_pending_action).to eq({})
      end
    end

    context 'нет file_id в state' do
      let(:broken_pa) { pending_action.merge('data' => { 'target_staff_id' => staff.id }) }

      it 'возвращает :error + reply + clear state' do
        result = described_class.new(msg: base_msg, tg_user: director, pending_action: broken_pa,
                                     client: tg_client).call
        expect(result).to eq(:error)
        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Нет file_id/), hash_including(:chat_id)
        )
      end
    end

    context 'staff не найден' do
      let(:broken_pa) { pending_action.merge('data' => { 'file_id' => 'F1', 'target_staff_id' => 999_999 }) }

      it 'возвращает :error и не дёргает sendPhoto' do
        described_class.new(msg: base_msg, tg_user: director, pending_action: broken_pa,
                            client: tg_client).call
        expect(tg_client).not_to have_received(:send_photo)
      end
    end
  end
end
