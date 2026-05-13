# frozen_string_literal: true

module Lead
  # Единая точка входа для всех каналов лидов в Telegram-бот АН.
  # Все 4 источника (сайт, TG DM, ручной /lead, CRM webhook) сходятся здесь:
  #
  #   Lead::Intake.call(source: 'site_form', payload: { ... })
  #
  # Каждый source имеет свой адаптер (SiteSource, TgDmSource, ManualSource,
  # CrmWebhookSource) — он отвечает за:
  #   1. Создание/поиск CRM-объекта (BuyerOrder | Property)
  #   2. Опц. вызов Topnlab::Client#import_client (создание order в CRM)
  #   3. Сборку metadata (phone, name, summary, budget) для карточки
  #
  # Сам Intake:
  #   * валидирует входные данные
  #   * создаёт LeadEvent
  #   * вызывает Telegram::WorkBot::LeadAnnouncer (синхронно — пока не Sidekiq)
  #   * возвращает Hash {success: bool, lead_event: LeadEvent|nil, error: str|nil}
  class Intake
    SUPPORTED_SOURCES = %w[site_form site_valuation site_mortgage tg_dm manual crm_webhook].freeze

    Result = Struct.new(:success, :lead_event, :error, keyword_init: true) do
      def success?
        success == true
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(source:, payload:, announcer: Telegram::WorkBot::LeadAnnouncer)
      @source = source.to_s
      @payload = payload.is_a?(Hash) ? payload.with_indifferent_access : {}
      @announcer_class = announcer
    end

    def call
      return Result.new(success: false, error: "unsupported source: #{@source}") unless valid_source?

      adapter = adapter_for(@source)
      ref, metadata = adapter.call(@payload)

      lead = LeadEvent.create!(
        lead_ref:         ref,
        source:           @source,
        tg_chat_id:       Telegram::TopicRegistry.chat_id,
        anchor_topic_key: 'dispatcher',
        current_stage:    'new',
        metadata:         metadata
      )

      @announcer_class.new(lead).call

      Result.new(success: true, lead_event: lead)
    rescue StandardError => e
      Rails.logger.error("[Lead::Intake] #{@source} failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      Result.new(success: false, error: "#{e.class}: #{e.message}")
    end

    private

    def valid_source?
      SUPPORTED_SOURCES.include?(@source)
    end

    def adapter_for(source)
      case source
      when 'site_form', 'site_valuation', 'site_mortgage' then SiteSource.new(source)
      when 'tg_dm'        then TgDmSource.new
      when 'manual'       then ManualSource.new
      when 'crm_webhook'  then CrmWebhookSource.new
      end
    end
  end
end
