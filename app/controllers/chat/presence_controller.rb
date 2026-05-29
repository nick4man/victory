# frozen_string_literal: true

module Chat
  class PresenceController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false
    before_action :authenticate_user!

    def online
      current_user.touch_activity!
      head :ok
    end

    def offline
      head :ok
    end
  end
end
