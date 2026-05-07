# frozen_string_literal: true

class Dashboard::MessagesController < Dashboard::BaseController
  def index
    @messages = user_messages.order(created_at: :desc)
  end

  def show
    @message = user_messages.find(params[:id])
  end

  def create
    @message = Message.new(message_params.merge(sender: current_user))
    if @message.save
      redirect_to dashboard_message_path(@message), notice: 'Сообщение отправлено'
    else
      render :index, status: :unprocessable_entity
    end
  end

  def unread
    @messages = current_user.received_messages.where(read: false).order(created_at: :desc)
    render :index
  end

  def mark_all_read
    current_user.received_messages.where(read: false).update_all(read: true, read_at: Time.current)
    redirect_to dashboard_messages_path, notice: 'Все сообщения прочитаны'
  end

  def mark_read
    message = current_user.received_messages.find(params[:id])
    message.mark_as_read!
    render json: { success: true }
  rescue ActiveRecord::RecordNotFound
    render json: { success: false }, status: :not_found
  end

  private

  def user_messages
    Message.where('sender_id = ? OR recipient_id = ?', current_user.id, current_user.id)
  end

  def message_params
    params.require(:message).permit(:body, :recipient_id, :property_id)
  end
end

