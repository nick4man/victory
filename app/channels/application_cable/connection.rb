# frozen_string_literal: true

module ApplicationCable
  # Identify each connection by visitor_token cookie (anonymous) and/or
  # current_user (authenticated). Either is enough — anonymous users still
  # need WebSocket access for the public chat widget.
  class Connection < ActionCable::Connection::Base
    identified_by :visitor_token, :current_user

    def connect
      self.current_user  = find_user
      self.visitor_token = cookies.signed[:visitor_token]

      reject_unauthorized_connection if visitor_token.blank? && current_user.blank?
    end

    private

    # Devise stores the user in the rack env via Warden.
    def find_user
      env['warden']&.user
    rescue StandardError
      nil
    end
  end
end
