# frozen_string_literal: true

module Crm
  # Кому из сотрудников бот физически может написать в личку — и почему не
  # может остальным.
  #
  # Появился из замера на проде: из 99 объектов, не доехавших до витрины,
  # персональное уведомление доходило только по 44. Остальные упирались не в
  # логику рассылки, а в три разные причины, которые снаружи выглядели
  # одинаково — «бот молчит».
  #
  # Поэтому причина возвращается явно: часть из них чинится кодом, часть —
  # только действием человека, и путать их дорого.
  #
  #   Crm::TelegramReachability.for(user)        # => :ok | :no_link | :no_dm | :inactive
  #   Crm::TelegramReachability.report(users)    # => { ok: [...], no_link: [...], ... }
  class TelegramReachability
    # Порядок важен: причины проверяются от самой ранней в цепочке к поздней,
    # иначе «нет лички» маскировало бы «нет связи вообще».
    REASONS = %i[no_link inactive no_dm ok].freeze

    HUMAN = {
      ok: 'бот может писать в личку',
      no_link: 'аккаунт в Telegram не связан с учёткой — связать через экран связывания',
      inactive: 'аккаунт в боте не активирован',
      no_dm: 'личка с ботом не открыта — сотрудник должен сам написать боту первым'
    }.freeze

    # @param user [User]
    # @return [Symbol] одна из REASONS
    def self.for(user)
      tg = user&.telegram_user
      return :no_link if tg.nil?
      return :inactive unless tg.status == 'active'
      return :no_dm if tg.dm_chat_id.blank?

      :ok
    end

    # @param users [Enumerable<User>]
    # @return [Hash{Symbol => Array<User>}] причина → сотрудники, все ключи присутствуют
    def self.report(users)
      base = REASONS.index_with { [] }
      users.each_with_object(base) { |u, acc| acc[self.for(u)] << u }
    end

    # Человекочитаемое объяснение — для сообщения директору.
    # @param reason [Symbol]
    # @return [String]
    def self.explain(reason)
      HUMAN.fetch(reason, reason.to_s)
    end
  end
end
