# frozen_string_literal: true

# Webhook endpoint registered in Topnlab admin to push card events:
#   POST /webhooks/topnlab
#   body (application/x-www-form-urlencoded): id=<int>&type=realty
#
# We enqueue a single-property import job. Realty is the only kind we mirror;
# `order` (buyer/tenant inquiries) and `service` (custom orders) are logged
# but not yet acted upon.
module Webhooks
  class TopnlabController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      id   = params[:id].to_s
      type = params[:type].to_s

      Rails.logger.info("Webhook Topnlab: id=#{id} type=#{type}")
      return head :unprocessable_entity if id.blank?

      case type
      when 'realty'
        TopnlabPropertyImportJob.perform_later(id)
      else
        Rails.logger.info("Webhook Topnlab: type=#{type.inspect} not handled (yet)")
      end

      head :ok
    end
  end
end
