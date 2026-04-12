# frozen_string_literal: true

class Dashboard::MessagesController < Dashboard::BaseController
  def index
    @messages = Message.where('sender_id = ? OR recipient_id = ?', current_user.id, current_user.id)
                       .order(created_at: :desc)
  end

  def show
    @message = Message.find(params[:id])
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
    @messages = Message.where(recipient: current_user, read_at: nil).order(created_at: :desc)
    render :index
  end

  def mark_all_read
    Message.where(recipient: current_user, read_at: nil).update_all(read_at: Time.current)
    redirect_to dashboard_messages_path, notice: 'Все сообщения прочитаны'
  end

  def mark_read
    message = Message.find(params[:id])
    message.update(read_at: Time.current) if message.recipient == current_user
    render json: { success: true }
  end

  private

  def message_params
    params.require(:message).permit(:body, :recipient_id, :property_id)
  end
end
