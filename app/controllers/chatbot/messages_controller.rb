# frozen_string_literal: true

module Chatbot
  class MessagesController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      message = params[:message].to_s
      Rails.logger.info("Chatbot received: #{message.truncate(200)}")
      render json: {
        reply: 'Спасибо за сообщение! Менеджер скоро ответит. (Чатбот в разработке)',
        timestamp: Time.current.iso8601
      }
    end

    def suggestions
      render json: {
        suggestions: [
          'Подобрать квартиру',
          'Помочь с ипотекой',
          'Заказать звонок',
          'Записаться на показ'
        ]
      }
    end
  end
end
