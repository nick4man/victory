# frozen_string_literal: true

# Imports a single Topnlab object by id. Triggered by /webhooks/topnlab and
# by the dashboard "обновить из CRM" button. After upserting the Property
# row, we run `publish_if_ready!` so the listing flips to active and lands
# in `Property.in_advertising` — the same scope that Avito/Cian/Yandex feeds
# read. Conversely, when CRM clears the ad flag, the listing auto-archives
# in the same tick.
class TopnlabPropertyImportJob < ApplicationJob
  queue_as :default

  def perform(topnlab_id)
    id = topnlab_id.to_s
    result = Topnlab::Importer.new.import_one(id)
    Rails.logger.info("TopnlabPropertyImportJob #{id}: #{result.inspect}")
    return unless result.is_a?(Hash) && result[:success]

    property = Property.unscoped.find_by(external_source: 'topnlab', external_id: id)
    return unless property

    published = property.publish_if_ready!
    Rails.logger.info(
      "TopnlabPropertyImportJob #{id}: published=#{published} status=#{property.status} " \
      "in_ad=#{property.in_ad} in_mls=#{property.in_mls}"
    )
  end
end
