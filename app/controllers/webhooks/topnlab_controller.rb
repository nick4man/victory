# frozen_string_literal: true

# Webhook endpoint registered in Topnlab admin to push card events:
#   POST /webhooks/topnlab?key=<KEY>
#   body (application/x-www-form-urlencoded): id=<int>&type=realty
#
# Auth: `key` URL/body param must match ENV['TOPNLAB_WEBHOOK_KEY']
# (falls back to ENV['TOPNLAB_API_KEY']). Compared constant-time via SHA256
# digests so timing attacks can't probe the secret.
#
# We enqueue a single-property import job. Realty is the only kind we mirror;
# `order` (buyer/tenant inquiries) and `service` (custom orders) are logged
# but not yet acted upon.
module Webhooks
  class TopnlabController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false
    before_action :require_topnlab_key

    def create
      id   = params[:id].to_s
      type = params[:type].to_s

      Rails.logger.info("Webhook Topnlab: id=#{id} type=#{type}")
      return head :unprocessable_entity if id.blank?

      case type
      when 'realty'
        TopnlabPropertyImportJob.perform_later(id)
      when 'order'
        # Re-sync a single BuyerOrder from CRM. Full orders sweep runs every 3h;
        # this keeps a specific order current when CRM pushes a change (stage move,
        # agent reassignment, etc.).
        TopnlabOrdersSyncJob.perform_later
      else
        Rails.logger.info("Webhook Topnlab: type=#{type.inspect} not handled (yet)")
      end

      head :ok
    end

    private

    def require_topnlab_key
      expected = ENV['TOPNLAB_WEBHOOK_KEY'].presence || ENV['TOPNLAB_API_KEY'].to_s
      submitted = params[:key].to_s
      if expected.blank?
        Rails.logger.warn('Webhook Topnlab: no TOPNLAB_WEBHOOK_KEY / TOPNLAB_API_KEY configured')
        head :service_unavailable and return
      end
      digest = ->(s) { ::Digest::SHA256.hexdigest(s.to_s) }
      return if ::ActiveSupport::SecurityUtils.secure_compare(digest.call(submitted), digest.call(expected))

      Rails.logger.warn("Webhook Topnlab: bad key from #{request.remote_ip}")
      head :forbidden
    end
  end
end
