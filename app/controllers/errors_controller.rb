# frozen_string_literal: true

# Custom branded error pages. Routes wired up in config/routes.rb at the
# bottom of the file (`get '404'`, etc.) and called by Rails when production
# raises ActionController::RoutingError or generic 5xx.
#
# Templates live under app/views/errors/.
class ErrorsController < ApplicationController
  skip_before_action :setup_meta_tags, raise: false

  layout 'application'

  def not_found
    render status: :not_found
  end

  def unprocessable_entity
    render status: :unprocessable_entity
  end

  def internal_server_error
    render status: :internal_server_error
  end
end
