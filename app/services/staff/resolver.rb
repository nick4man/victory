# frozen_string_literal: true

module Staff
  # Resolver между CRM-staff и нашим TelegramUser.
  #
  # Сейчас CRM = Topnlab (через `Topnlab::Client#get_users`). При миграции в
  # собственную CRM нужно переписать ТОЛЬКО тело `#find_by_email` — query'ить
  # локальную `User` таблицу вместо Topnlab API. Команда `/link` и весь
  # call-site код не меняются — это abstraction layer.
  #
  # @return [Hash, nil] CRM-user payload в формате Topnlab:
  #   { "id" => Integer, "firstname" => String, "lastname" => String, "email" => String, ... }
  #   или nil если не найден / CRM недоступен.
  class Resolver
    def initialize(client: Topnlab::Client.new)
      @client = client
    end

    def find_by(email:)
      return nil if email.blank?

      target = email.to_s.downcase.strip
      @client.get_users.find { |u| u['email'].to_s.downcase.strip == target }
    rescue Topnlab::Client::Error => e
      Rails.logger.warn("[Staff::Resolver] CRM unavailable: #{e.message}")
      nil
    end
  end
end
