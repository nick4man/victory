# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DocumentIntake::ParserJob, type: :job do
  let(:uploader) { instance_double('User', id: 1) }
  let(:doc) do
    instance_double(
      'ClientDocument',
      id:            42,
      tg_file_id:    'BQACAgITest123',
      document_kind: 'passport',
      status:        'received',
      status_ocr_completed?: false,
      status_reviewed?:      false,
      parsed_data_masked:    { 'passport_series' => '12 ** ******' },
      # Phase 9 Iter 5 добавил в ParserJob#perform ветку retry-mirror, которая
      # читает nextcloud_path до всякого OCR (parser_job.rb:29). Без стаба
      # verified double честно падал на незнакомом сообщении.
      nextcloud_path: nil
    )
  end

  let(:tg_client) { instance_double('Telegram::Client') }
  let(:yv_client) { instance_double('YandexVision::Client') }
  let(:tmp_file)  { instance_double('Tempfile', read: 'binary_image_data', close: nil, unlink: nil) }

  let(:mock_passport_text) do
    <<~TEXT
      РОССИЙСКАЯ ФЕДЕРАЦИЯ
      ПАСПОРТ
      12 34 567890
      ИВАНОВ
      ИВАН
      ИВАНОВИЧ
      01.02.1985
    TEXT
  end

  let(:mock_parsed) do
    {
      passport_series: '1234',
      passport_number: '567890',
      last_name:       'ИВАНОВ',
      first_name:      'ИВАН',
      middle_name:     'ИВАНОВИЧ',
      birth_date:      '1985-02-01',
      confidence:      1.0
    }
  end

  before do
    allow(ClientDocument).to receive(:find_by).with(id: 42).and_return(doc)
    allow(Telegram::Client).to receive(:new).and_return(tg_client)
    allow(YandexVision::Client).to receive(:new).and_return(yv_client)

    allow(tg_client).to receive(:download_file).and_return(tmp_file)
    allow(tg_client).to receive(:send_message)

    allow(yv_client).to receive(:text_detection).and_return(
      { 'text' => mock_passport_text, 'blocks' => [] }
    )

    allow(DocumentIntake::PassportParser).to receive(:call)
      .with(mock_passport_text)
      .and_return(mock_parsed)

    allow(doc).to receive(:update!)
    allow(doc).to receive(:parsed_data).and_return(mock_parsed)

    # Зеркалирование в Nextcloud и авто-привязка к DocumentRequirement — отдельные
    # ответственности со своими спеками. Здесь они только мешают: обе лезут в
    # ассоциации ClientDocument (property / inquiry / inquiry_id) и дальше в сеть,
    # а эти примеры про OCR-конвейер. Оба сервиса подключены к ParserJob уже
    # после того, как спек был написан, — отсюда и падения verified double.
    allow(DocumentIntake::NextcloudMirror).to receive(:call).and_return(
      DocumentIntake::NextcloudMirror::Result.new(
        nextcloud_path: nil, document_upload: nil, error: 'stubbed in spec'
      )
    )

    allow(DocumentChecklist::AutoMatchToRequirement).to receive(:call).and_return(
      DocumentChecklist::AutoMatchToRequirement::Result.new(
        status: :skipped, requirement: nil, lead_event: nil, reason: 'stubbed in spec'
      )
    )
  end

  describe '#perform' do
    it 'marks document as ocr_processing then ocr_completed' do
      expect(doc).to receive(:update!).with(status: :ocr_processing).ordered
      expect(doc).to receive(:update!).with(
        hash_including(status: :ocr_completed, parsed_data: mock_parsed)
      ).ordered

      described_class.new.perform(42)
    end

    it 'dispatches to PassportParser for passport documents' do
      expect(DocumentIntake::PassportParser).to receive(:call).with(mock_passport_text)
      described_class.new.perform(42)
    end

    it 'sends staff notification after completion' do
      # notify_staff читает ENV.fetch('TELEGRAM_STAFF_CHAT_ID', nil), а спек
      # подменял только ENV.[] — из-за чего в тест подставлялся настоящий
      # chat_id рабочей группы из .env.
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('TELEGRAM_STAFF_CHAT_ID', nil).and_return('-1001234567890')

      expect(tg_client).to receive(:send_message).with(
        anything,
        hash_including(chat_id: '-1001234567890')
      )

      described_class.new.perform(42)
    end

    context 'when document not found' do
      before do
        allow(ClientDocument).to receive(:find_by).with(id: 999).and_return(nil)
      end

      it 'returns early without error' do
        expect { described_class.new.perform(999) }.not_to raise_error
      end
    end

    context 'when document already completed' do
      before do
        allow(doc).to receive(:status_ocr_completed?).and_return(true)
      end

      it 'skips processing (idempotency)' do
        expect(doc).not_to receive(:update!).with(status: :ocr_processing)
        described_class.new.perform(42)
      end
    end

    context 'when Yandex Vision fails' do
      before do
        allow(yv_client).to receive(:text_detection).and_return(nil)
        allow(DocumentIntake::PassportParser).to receive(:call).with('').and_return(
          { confidence: 0.0 }
        )
        allow(doc).to receive(:parsed_data).and_return({ confidence: 0.0 })
      end

      it 'still completes with empty parsed_data' do
        expect(doc).to receive(:update!).with(hash_including(status: :ocr_completed))
        described_class.new.perform(42)
      end
    end
  end
end
