# frozen_string_literal: true

class Forms::AgentContactsController < ApplicationController
  def create
    name = params[:name]
    phone = params[:phone]
    message = params[:message]

    # Send notification email (silently fail if mailer is broken)
    AdminMailer.agent_contact(name, phone, message).deliver_later rescue nil

    render json: { success: true, message: 'Заявка отправлена' }
  end
end
