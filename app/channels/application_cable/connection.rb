# frozen_string_literal: true

module ApplicationCable
  # Identify each connection by visitor_token cookie (anonymous) and/or
  # current_user (Devise — off на проекте, для будущей совместимости) и/или
  # current_cabinet_user_id (A7 magic-link session). Любой identifier
  # достаточен — anonymous users still need WebSocket для public chat widget.
  class Connection < ActionCable::Connection::Base
    identified_by :visitor_token, :current_user, :current_cabinet_user_id

    def connect
      self.current_user            = find_user
      self.visitor_token           = cookies.signed[:visitor_token]
      self.current_cabinet_user_id = find_cabinet_user_id

      reject_unauthorized_connection if visitor_token.blank? && current_user.blank? &&
                                        current_cabinet_user_id.blank?
    end

    private

    # Devise stores the user in the rack env via Warden.
    def find_user
      env['warden']&.user
    rescue StandardError
      nil
    end

    # A7 Phase 1: session[:cabinet_user_id] set'ится в Cabinet::AuthController#verify.
    # ActionCable cookies — encrypted session cookie через
    # Rails.application.config.session_options[:key].
    def find_cabinet_user_id
      session_key = Rails.application.config.session_options[:key]
      cookie = cookies.encrypted[session_key]
      cookie.is_a?(Hash) ? cookie['cabinet_user_id'] : nil
    rescue StandardError => e
      Rails.logger.debug("[ApplicationCable] cabinet_user_id read failed: #{e.message}")
      nil
    end
  end
end
