# frozen_string_literal: true

class Chat::MessagesController < ApplicationController
  before_action :authenticate_user!

  def create
    render json: { success: true }
  end
end
