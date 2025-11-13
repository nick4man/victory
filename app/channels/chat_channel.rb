# frozen_string_literal: true

# Chat Channel
# Real-time chat using ActionCable
class ChatChannel < ApplicationCable::Channel
  def subscribed
    # Authenticate user
    reject unless current_user
    
    # Subscribe to user's personal chat stream
    stream_for current_user
    
    # Also subscribe to general support channel if user is client
    stream_from "support_chat_#{current_user.id}" if current_user.client?
    
    # Notify online status
    update_online_status(true)
    broadcast_online_status
    
    Rails.logger.info "User #{current_user.id} subscribed to chat"
  end

  def unsubscribed
    # Update offline status
    update_online_status(false)
    broadcast_online_status
    
    Rails.logger.info "User #{current_user.id} unsubscribed from chat"
  end

  # Receive message from client
  def receive(data)
    return unless current_user
    
    case data['action']
    when 'send_message'
      send_message(data)
    when 'typing'
      broadcast_typing_indicator(data)
    when 'stop_typing'
      broadcast_stop_typing(data)
    when 'mark_read'
      mark_messages_read(data)
    end
  end

  private

  def send_message(data)
    message = Message.new(
      sender: current_user,
      receiver_id: data['receiver_id'],
      content: data['content'],
      message_type: data['message_type'] || 'text',
      conversation_id: find_or_create_conversation(data['receiver_id'])
    )

    if message.save
      # Broadcast to receiver
      receiver = User.find(data['receiver_id'])
      ChatChannel.broadcast_to(
        receiver,
        {
          action: 'new_message',
          message: serialize_message(message),
          sender: serialize_user(current_user)
        }
      )

      # Broadcast to sender (confirmation)
      ChatChannel.broadcast_to(
        current_user,
        {
          action: 'message_sent',
          message: serialize_message(message)
        }
      )

      # Send push notification if receiver is offline
      send_push_notification(receiver, message) unless receiver.online?

      # Track event
      track_event('message_sent', {
        message_id: message.id,
        receiver_id: receiver.id,
        message_type: message.message_type
      })
    else
      # Broadcast error to sender
      ChatChannel.broadcast_to(
        current_user,
        {
          action: 'error',
          message: 'Failed to send message',
          errors: message.errors.full_messages
        }
      )
    end
  end

  def broadcast_typing_indicator(data)
    receiver = User.find_by(id: data['receiver_id'])
    return unless receiver

    ChatChannel.broadcast_to(
      receiver,
      {
        action: 'user_typing',
        user_id: current_user.id,
        user_name: current_user.full_name
      }
    )
  end

  def broadcast_stop_typing(data)
    receiver = User.find_by(id: data['receiver_id'])
    return unless receiver

    ChatChannel.broadcast_to(
      receiver,
      {
        action: 'user_stopped_typing',
        user_id: current_user.id
      }
    )
  end

  def mark_messages_read(data)
    Message.where(
      sender_id: data['sender_id'],
      receiver_id: current_user.id,
      read: false
    ).update_all(read: true, read_at: Time.current)

    # Notify sender that messages were read
    sender = User.find_by(id: data['sender_id'])
    return unless sender

    ChatChannel.broadcast_to(
      sender,
      {
        action: 'messages_read',
        reader_id: current_user.id,
        conversation_id: data['conversation_id']
      }
    )
  end

  def find_or_create_conversation(receiver_id)
    # Find existing conversation between users
    conversation_id = Message.where(
      '(sender_id = ? AND receiver_id = ?) OR (sender_id = ? AND receiver_id = ?)',
      current_user.id, receiver_id, receiver_id, current_user.id
    ).first&.conversation_id

    # Generate new conversation ID if not found
    conversation_id || SecureRandom.uuid
  end

  def update_online_status(online)
    current_user.update_column(:online, online)
    current_user.update_column(:last_seen_at, Time.current)
  end

  def broadcast_online_status
    ActionCable.server.broadcast(
      'online_users',
      {
        user_id: current_user.id,
        online: current_user.online?,
        last_seen_at: current_user.last_seen_at
      }
    )
  end

  def serialize_message(message)
    {
      id: message.id,
      content: message.content,
      message_type: message.message_type,
      created_at: message.created_at.iso8601,
      sender_id: message.sender_id,
      receiver_id: message.receiver_id,
      read: message.read,
      conversation_id: message.conversation_id
    }
  end

  def serialize_user(user)
    {
      id: user.id,
      name: user.full_name,
      email: user.email,
      avatar_url: user.avatar_url,
      online: user.online?
    }
  end

  def send_push_notification(user, message)
    # Send push notification (implement based on your notification system)
    Rails.logger.info "Sending push notification to user #{user.id} for message #{message.id}"
    
    # Example:
    # PushNotificationService.send(
    #   user: user,
    #   title: "New message from #{current_user.full_name}",
    #   body: message.content,
    #   data: { message_id: message.id }
    # )
  rescue StandardError => e
    Rails.logger.error "Failed to send push notification: #{e.message}"
  end
  
  def track_event(event_name, properties = {})
    # Track analytics event
    Rails.logger.info "Chat event: #{event_name} - #{properties}"
  rescue StandardError => e
    Rails.logger.error "Failed to track event: #{e.message}"
  end
end

