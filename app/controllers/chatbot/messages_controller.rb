# frozen_string_literal: true

class Chatbot::MessagesController < ApplicationController
  def create
    render json: {
      reply: 'Здравствуйте! Я помогу вам найти идеальную недвижимость. Чем могу помочь?'
    }
  end
end
