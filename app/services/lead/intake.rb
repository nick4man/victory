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
  #   * возвращает Result {success: bool, lead_event: LeadEvent|nil, error: str|nil, threaded: bool}
  class Intake
    SUPPORTED_SOURCES = %w[site_form site_valuation site_mortgage tg_dm manual crm_webhook].freeze

    # threaded — заявка дописана в уже открытую карточку, а не создала новую.
    # Метаданные возвращённого lead_event в этом случае принадлежат ПЕРВОЙ
    # заявке клиента: признак «вернулся» по ним не прочитать, только отсюда.
    Result = Struct.new(:success, :lead_event, :error, :threaded, keyword_init: true) do
      def success?
        success == true
      end

      def threaded?
        threaded == true
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
      result = adapter.call(@payload)

      # A7 Phase 1 gate: adapter returns nil → skip lead generation entirely
      # (internal staff submission или другая reason'а из адаптера).
      if result.nil?
        Rails.logger.info("[Lead::Intake] #{@source} adapter returned nil — skipping LeadEvent creation")
        return Result.new(success: true, lead_event: nil, error: nil)
      end

      ref, metadata = result

      # BOTTLENECK — вернувшийся клиент дописывается в существующую карточку,
      # а не плодит вторую. TgDmSource при cross-channel match уже дописал
      # сообщение в metadata['client_history'] существующего LeadEvent; до этого
      # гейта Intake всё равно создавал новую запись и публиковал второй анкор.
      # Две карточки на одного клиента — это не только шум в диспетчерской:
      # сегмент ставят на одной, показ пишут на другой, и лид уходит в матрицу
      # «сегмент × кто показывал» как «не указан».
      #
      # Гейт смотрит на thread_to_existing_lead, а НЕ на returning_client:
      # второй флаг перегружен — SiteSource ставит его знакомому клиенту просто
      # для тёплого бейджа, ничего не склеивая. По нему заявка с сайта осталась
      # бы без карточки вообще (найдено ревью PR #65).
      #
      # Только открытые лиды: клиент, чья сделка закрылась полгода назад, должен
      # получить новую карточку, а не дописку в closed_won без анкора.
      if metadata.is_a?(Hash) && metadata['thread_to_existing_lead'] == true
        existing = LeadEvent.open
                            .where(lead_ref_type: ref.class.name, lead_ref_id: ref.id)
                            .order(created_at: :desc).first
        if existing
          Rails.logger.info(
            "[Lead::Intake] #{@source} returning client → append to lead##{existing.id}, no new LeadEvent"
          )
          return Result.new(success: true, lead_event: existing, error: nil, threaded: true)
        end
      end

      lead = LeadEvent.create!(
        lead_ref:         ref,
        property:         Lead::PropertyResolver.for_ref(ref),
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
