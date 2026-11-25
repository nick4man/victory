# frozen_string_literal: true

require 'open-uri'
require 'digest/md5'

# Downloads photos from Topnlab CDN and attaches them to Property via Active Storage.
# Idempotent: filenames derived from MD5 of URL — won't re-attach the same image.
class TopnlabPhotoSyncJob < ApplicationJob
  queue_as :low_priority

  MAX_PER_PROPERTY = 30
  TIMEOUT          = 30 # seconds

  def perform(property_id, urls)
    property = Property.unscoped.find_by(id: property_id)
    return unless property

    urls = Array(urls).compact.uniq
    return if urls.empty?

    existing = property.images.attachments.map { |a| a.blob.filename.to_s }.to_set

    # Дедуп строго до капа: Topnlab отдаёт photos в хронологическом порядке,
    # иначе 30 старых в начале массива навсегда отсекают новые (#265).
    urls = urls.reject { |url| existing.include?(filename_for(url)) }.first(MAX_PER_PROPERTY)
    return if urls.empty?

    attached = 0
    urls.each do |url|
      attach_one(property, url, filename_for(url)) && (attached += 1)
    rescue StandardError => e
      Rails.logger.warn("TopnlabPhoto: #{property.id} #{url} → #{e.class}: #{e.message}")
    end

    property.update_column(:images_count, property.images.count) if attached.positive?
  end

  private

  def filename_for(url)
    "topnlab-#{Digest::MD5.hexdigest(url)[0, 16]}#{ext_for(url)}"
  end

  def attach_one(property, url, filename)
    io = URI.parse(url).open(read_timeout: TIMEOUT, open_timeout: 10)
    property.images.attach(io: io, filename: filename, content_type: io.content_type || 'image/jpeg')
    true
  end

  def ext_for(url)
    e = File.extname(URI.parse(url).path)
    e.presence || '.jpg'
  end
end
