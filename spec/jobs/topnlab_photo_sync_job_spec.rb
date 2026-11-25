# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TopnlabPhotoSyncJob do
  let(:property) { create(:property) }
  # Минимальный JPEG: open-uri получает его телом ответа, содержимое не декодируется.
  let(:jpeg) { "\xFF\xD8\xFF\xD9".b }

  def url_for(n)
    "https://cdn.topnlab.example/photos/#{n}.jpg"
  end

  # Та же формула, что в джобе: filename из MD5 url — ключ дедупликации.
  def filename_for(url)
    "topnlab-#{Digest::MD5.hexdigest(url)[0, 16]}.jpg"
  end

  def attach_existing(url)
    property.images.attach(io: StringIO.new(jpeg), filename: filename_for(url), content_type: 'image/jpeg')
  end

  def stub_photos(urls)
    urls.each do |url|
      stub_request(:get, url).to_return(body: jpeg, headers: { 'Content-Type' => 'image/jpeg' })
    end
  end

  def attached_filenames
    property.reload.images.attachments.map { |a| a.blob.filename.to_s }
  end

  # Регрессия #265: кап MAX_PER_PROPERTY применялся ДО дедупликации по
  # filename, поэтому у объекта с 30 скачанными фото новые (Topnlab отдаёт их
  # в конце массива photos) отсекались навсегда — джоба «успешно» ничего не
  # скачивала и не логировала.
  it 'докачивает новые фото, когда первые 30 слотов payload заняты старыми' do
    old_urls = Array.new(30) { |i| url_for(i) }
    new_urls = [url_for(30), url_for(31)]
    old_urls.each { |url| attach_existing(url) }
    stub_photos(old_urls + new_urls)

    described_class.new.perform(property.id, old_urls + new_urls)

    expect(attached_filenames).to include(*new_urls.map { |url| filename_for(url) })
    expect(property.images.attachments.count).to eq(32)
    old_urls.each { |url| expect(WebMock).not_to have_requested(:get, url) }
  end

  it 'применяет лимит к новым фото после дедупликации' do
    urls = Array.new(40) { |i| url_for(i) }
    stub_photos(urls)

    described_class.new.perform(property.id, urls)

    expect(property.images.attachments.count).to eq(described_class::MAX_PER_PROPERTY)
  end

  it 'не делает HTTP-запросов за уже имеющимися фото' do
    urls = Array.new(5) { |i| url_for(i) }
    urls.each { |url| attach_existing(url) }

    described_class.new.perform(property.id, urls)

    expect(property.reload.images.attachments.count).to eq(5)
    urls.each { |url| expect(WebMock).not_to have_requested(:get, url) }
  end

  it 'обновляет images_count после докачки' do
    urls = [url_for(0), url_for(1)]
    stub_photos(urls)

    described_class.new.perform(property.id, urls)

    expect(property.reload.images_count).to eq(2)
  end
end
