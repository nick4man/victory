# frozen_string_literal: true

module Webhooks
  class YookassaController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      Rails.logger.info("Webhook YooKassa: #{request.raw_post.truncate(2000)}")
      head :ok
    end
  end
end
