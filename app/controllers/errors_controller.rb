# frozen_string_literal: true

# Custom branded error pages. Routes wired up in config/routes.rb at the
# bottom of the file (`get '404'`, etc.) and called by Rails when production
# raises ActionController::RoutingError or generic 5xx, plus by the catch-all
# `match '*unmatched'` that turns typos in the address bar into branded 404s
# instead of Rails debug pages / public/404.html.
#
# Templates live under app/views/errors/.
class ErrorsController < ApplicationController
  skip_before_action :setup_meta_tags, raise: false

  layout 'application'

  def not_found
    respond_with_status(:not_found, 'Not found')
  end

  def unprocessable_entity
    respond_with_status(:unprocessable_entity, 'Unprocessable entity')
  end

  def internal_server_error
    respond_with_status(:internal_server_error, 'Internal server error')
  end

  private

  # HTML callers get the branded view; everything else (API, fetch with
  # Accept: application/json, turbo-stream, plain text) gets a lightweight
  # body so the catch-all never blows up with a template-missing 500.
  def respond_with_status(status, message)
    respond_to do |format|
      format.html { render action_name, status: status }
      format.json { render json: { error: message, status: status }, status: status }
      format.any  { render plain: message, status: status }
    end
  end
end
