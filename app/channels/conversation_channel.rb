# frozen_string_literal: true

# Per-conversation broadcast channel for the public chat widget.
# Visitors subscribe via { id: conversation_id } and only see streams
# for their own conversation (matched by signed visitor_token cookie or
# logged-in user).
class ConversationChannel < ApplicationCable::Channel
  def subscribed
    conv = Conversation.find_by(id: params[:id])
    return reject if conv.nil?
    return reject unless authorized?(conv)

    stream_for conv
  end

  private

  def authorized?(conv)
    return true if conv.user_id.present? && connection.current_user&.id == conv.user_id
    token = connection.visitor_token
    conv.visitor_token.present? && conv.visitor_token == token
  end
end
