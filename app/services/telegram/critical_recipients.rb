# frozen_string_literal: true

module Telegram
  # Phase 11 Iter 25 — Cascade resolver для критичных DM-получателей.
  #
  # Зачем: до этого фикса все critical notifications (CRM-sync failure,
  # job-failure alerts, KPI digest) били в `TelegramUser.directors.active`.
  # Один director (Оксана) с status=inactive (отпуск/блок/уехала) → critical
  # alerts уходят в void, никто не получает. Single-point-of-failure для
  # operational visibility.
  #
  # Fix — cascade:
  #   1. role=director + active — primary
  #   2. role=admin + active — secondary (тех-руководитель видит проблемы)
  #   3. is_manager=true + active — tertiary (хоть кто-то узнает)
  #   4. Empty + Rails.logger.error — последний резерв, явный сигнал в логах
  #
  # Использование:
  #   recipients = Telegram::CriticalRecipients.resolve
  #   recipients.each { |tu| send_dm(tu, ...) }
  #
  # Контракт: ВСЕГДА возвращает массив (возможно пустой). Caller'у не нужно
  # обрабатывать nil. Если empty — caller сам может Rails.logger.error.
  class CriticalRecipients
    LEVELS = %i[directors admins managers].freeze

    def self.resolve(min_level: :directors)
      new(min_level: min_level).resolve
    end

    def initialize(min_level: :directors)
      @min_level = min_level
    end

    # @return [Array<TelegramUser>] non-empty если хоть кто-то из cascade найден.
    def resolve
      tiers = build_tiers
      tiers.each do |tier|
        recipients = tier.call.to_a
        return recipients if recipients.any?
      end

      Rails.logger.error('[CriticalRecipients] EMPTY cascade — no director, admin, or manager active. ' \
                         'Critical alerts будут потеряны до восстановления.')
      []
    end

    private

    def build_tiers
      # Lambda-tier'ы — lazy eval (не дёргаем БД пока не нужно)
      directors = -> { TelegramUser.directors.where(status: 'active') }
      admins    = -> { TelegramUser.where(role: 'admin', status: 'active') }
      managers  = -> { TelegramUser.managers.where(status: 'active') }

      case @min_level
      when :directors then [directors, admins, managers]
      when :admins    then [admins, managers]
      when :managers  then [managers]
      else [directors, admins, managers]
      end
    end
  end
end
