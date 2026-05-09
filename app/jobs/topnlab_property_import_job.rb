# frozen_string_literal: true

# Imports a single Topnlab object by id. Triggered by /webhooks/topnlab.
class TopnlabPropertyImportJob < ApplicationJob
  queue_as :default

  def perform(topnlab_id)
    result = Topnlab::Importer.new.import_one(topnlab_id.to_s)
    Rails.logger.info("TopnlabPropertyImportJob #{topnlab_id}: #{result.inspect}")
  end
end
