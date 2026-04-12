# frozen_string_literal: true

class Chat::ConversationsController < ApplicationController
  before_action :authenticate_user!

  def index
    @conversations = []
  end

  def show
    @messages = []
  end

  def create
    redirect_to chat_conversations_path
  end
end
