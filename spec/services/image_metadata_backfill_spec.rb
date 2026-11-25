# frozen_string_literal: true

require 'rails_helper'

# Бэкфилл width/height у блобов картинок с пустым анализом (issue #53).
# Анализатор в тест-окружении не гарантирует libvips, поэтому metadata
# Vips-подкласса стабится — прогоняется сама механика выборки/записи/счётчиков.
RSpec.describe ImageMetadataBackfill do
  # 1x1 PNG.
  PNG_BYTES = Base64.decode64(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
  ).freeze

  def create_image_blob(metadata: { 'identified' => true, 'analyzed' => true })
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(PNG_BYTES),
      filename: 'tiny.png',
      content_type: 'image/png',
      metadata: metadata
    )
  end

  # Возвращает размеры для всех картинок; override — хэш blob.id => metadata
  # или исключение для точечного сбоя.
  def stub_analyzer(override = {})
    allow_any_instance_of(ActiveStorage::Analyzer::ImageAnalyzer::Vips).to receive(:metadata) do |analyzer|
      blob = analyzer.blob
      case (v = override[stub_analyzer__id_of(blob)])
      when nil    then { width: 640, height: 480 }
      when Exception then raise v
      else v
      end
    end
  end

  # instance_double недоступен внутри allow_any_instance_of-блока — берём id напрямую.
  def stub_analyzer__id_of(blob)
    blob.id
  end

  before do
    stub_analyzer
    # mini_magick-гем в тестах есть, бинарника convert — нет: глушим и второй
    # image-подкласс, чтобы механика прогона не зависела от окружения.
    allow_any_instance_of(ActiveStorage::Analyzer::ImageAnalyzer::ImageMagick)
      .to receive(:metadata).and_return({})
  end

  it 'записывает width/height блобу без размеров и считает его done' do
    blob = create_image_blob
    expect(blob.metadata['width']).to be_nil

    result = described_class.call(batch_size: 10, sleep_seconds: 0)

    expect(blob.reload.metadata).to include('width' => 640, 'height' => 480, 'analyzed' => true)
    expect(result).to eq(done: 1, failed: 0, no_dims: 0, total: 1)
  end

  it 'пропускает блобы, у которых размеры уже есть' do
    create_image_blob(metadata: { 'identified' => true, 'analyzed' => true, 'width' => 100, 'height' => 80 })
    expect_any_instance_of(ActiveStorage::Blob).not_to receive(:analyze)

    result = described_class.call(sleep_seconds: 0)

    expect(result).to eq(done: 0, failed: 0, no_dims: 0, total: 0)
  end

  it 'берёт блоб, у которого есть width, но нет height' do
    blob = create_image_blob(metadata: { 'identified' => true, 'analyzed' => true, 'width' => 100 })
    expect(blob.metadata['height']).to be_nil

    described_class.call(sleep_seconds: 0)

    expect(blob.reload.metadata).to include('width' => 640, 'height' => 480)
  end

  it 'берёт блоб с NULL metadata' do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(PNG_BYTES), filename: 'nil-meta.png', content_type: 'image/png', metadata: nil
    )

    result = described_class.call(sleep_seconds: 0)

    expect(result[:total]).to eq(1)
    expect(blob.reload.metadata).to include('width' => 640, 'height' => 480)
  end

  it 'не трогает не-картинки' do
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('plain text'),
      filename: 'note.txt',
      content_type: 'text/plain'
    )

    result = described_class.call(sleep_seconds: 0)

    expect(result[:total]).to eq(0)
  end

  it 'dry_run только считает, metadata не меняет' do
    blob = create_image_blob

    result = described_class.call(sleep_seconds: 0, dry_run: true)

    expect(result).to eq(done: 1, failed: 0, no_dims: 0, total: 1)
    expect(blob.reload.metadata['width']).to be_nil
  end

  it 'ошибка анализа одного блоба не роняет прогон: failed считается, остальные делаются' do
    bad = create_image_blob
    good = create_image_blob
    allow_any_instance_of(ActiveStorage::Analyzer::ImageAnalyzer::Vips).to receive(:metadata) do |analyzer|
      raise IOError, 'storage gone' if analyzer.blob.id == bad.id

      { width: 640, height: 480 }
    end
    allow(Rails.logger).to receive(:warn)

    result = described_class.call(sleep_seconds: 0)

    expect(result).to eq(done: 1, failed: 1, no_dims: 0, total: 2)
    expect(good.reload.metadata).to include('width' => 640)
    expect(bad.reload.metadata['width']).to be_nil
    expect(Rails.logger).to have_received(:warn).with(/blob_id=#{bad.id}.*storage gone/)
  end

  it 'блоб, у которого после анализа размеры не появились, считается no_dims' do
    create_image_blob
    allow_any_instance_of(ActiveStorage::Analyzer::ImageAnalyzer::Vips).to receive(:metadata).and_return({})

    result = described_class.call(sleep_seconds: 0)

    expect(result).to eq(done: 0, failed: 0, no_dims: 1, total: 1)
  end

  it 'limit ограничивает выборку: обработаны ровно limit блобов, остальные не тронуты' do
    blobs = 3.times.map { create_image_blob }
    untouched = blobs.last

    result = described_class.call(sleep_seconds: 0, limit: 2)

    expect(result).to eq(done: 2, failed: 0, no_dims: 0, total: 2)
    expect(untouched.reload.metadata['width']).to be_nil
  end

  it 'блобов больше batch_size: find_each обходит все пачки без пропусков' do
    5.times { create_image_blob }

    result = described_class.call(batch_size: 2, sleep_seconds: 0)

    expect(result).to eq(done: 5, failed: 0, no_dims: 0, total: 5)
  end

  it 'делает throttle-паузу между блобами только в реальном прогоне' do
    create_image_blob
    backfill = described_class.new(sleep_seconds: 0.5)
    allow(backfill).to receive(:sleep)

    backfill.call

    expect(backfill).to have_received(:sleep).with(0.5).once
  end

  it 'dry_run не делает throttle-пауз' do
    create_image_blob
    backfill = described_class.new(sleep_seconds: 0.5, dry_run: true)
    allow(backfill).to receive(:sleep)

    backfill.call

    expect(backfill).not_to have_received(:sleep)
  end
end
