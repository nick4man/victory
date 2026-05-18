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

    # Phase 13 Iter 49 — Result struct с tier-info вместо bare array.
    # Caller'ы (ApplicationJob, LeadAssignment, TaskBatchConfirmCallback)
    # могут показать в alert text 'routed to admins tier' если tier !=
    # primary. До фикса manager получал director-level alert не зная
    # что он fallback.
    Result = Struct.new(:recipients, :tier, keyword_init: true) do
      def each(&block); recipients.each(&block); end
      def any?; recipients.any?; end
      def empty?; recipients.empty?; end
      def size; recipients.size; end
      def fallback?; tier != 'directors'; end
    end

    def self.resolve(min_level: :directors)
      new(min_level: min_level).resolve
    end

    def initialize(min_level: :directors)
      @min_level = min_level
    end

    # @return [Result] {recipients:, tier:}. recipients — Array (возможно
    # empty); tier — 'directors' / 'admins' / 'managers' / 'empty'.
    def resolve
      tiers = build_tiers
      tiers.each do |name, tier_lambda|
        recipients = tier_lambda.call.to_a
        if recipients.any?
          Rails.logger.info("[CriticalRecipients] tier=#{name} count=#{recipients.size}") if name != :directors
          return Result.new(recipients: recipients, tier: name.to_s)
        end
      end

      Rails.logger.error('[CriticalRecipients] EMPTY cascade — no director, admin, or manager active. ' \
                         'Critical alerts будут потеряны до восстановления.')
      Result.new(recipients: [], tier: 'empty')
    end

    private

    def build_tiers
      # Named tier'ы (name, lambda) — name нужен для logging + Result.tier.
      directors = [:directors, -> { TelegramUser.directors.where(status: 'active') }]
      admins    = [:admins,    -> { TelegramUser.where(role: 'admin', status: 'active') }]
      managers  = [:managers,  -> { TelegramUser.managers.where(status: 'active') }]

      case @min_level
      when :directors then [directors, admins, managers]
      when :admins    then [admins, managers]
      when :managers  then [managers]
      else [directors, admins, managers]
      end
    end
  end
end
