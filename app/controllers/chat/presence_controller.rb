# frozen_string_literal: true

class Chat::PresenceController < ApplicationController
  def update
    render json: { success: true }
  end
end
