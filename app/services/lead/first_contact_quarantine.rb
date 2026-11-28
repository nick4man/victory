# frozen_string_literal: true

module Lead
  # Карантин первого контакта (issue #286): мягкая защита от спама с новых
  # прокси, которые фидовые блэклисты ещё не знают.
  #
  # Условие карантина — оба сигнала одновременно:
  #   1. IP НИ РАЗУ не оставлял заявку (нет локальной истории — доверять
  #      нечему);
  #   2. текст не прошёл классификацию содержимого (LLM-фильтр форм —
  #      отдельная задача того же фронта; сюда приезжает готовый вердикт).
  #
  # Карантинный лид НЕ теряется: Inquiry создаётся с меткой quarantine в
  # metadata (образец — suspicious из #239) для ручной разборки, но карточка
  # в ДИСПЕТЧЕРСКУЮ не публикуется — Inquiry#push_to_work_bot видит метку и
  # пропускает пуш. Инвариант владельца: мусор не попадает в CRM — метка
  # ставится в attrs ДО create, поэтому LeadEvent/CrmCard/экспорт не
  # создаются вообще.
  #
  # Использование в контроллере формы (до Inquiry.create!):
  #   attrs = Lead::FirstContactQuarantine.new(ip: request.remote_ip,
  #                                            classification: verdict).apply(attrs)
  class FirstContactQuarantine
    METADATA_KEY = 'quarantine'
    REASON_KEY   = 'quarantine_reason'
    AT_KEY       = 'quarantined_at'
    REASON       = 'first_contact_negative_classification'

    def initialize(ip:, classification:)
      @ip = ip.to_s.strip
      @classification = classification
    end

    # true — заявку с этими ip/classification создаём в карантине.
    def call
      negative? && first_contact?
    end

    # Дописывает карантинную метку в attrs Inquiry (до create), не затирая
    # уже выставленную metadata (например, suspicious из #239).
    def apply(attrs)
      return attrs unless call

      metadata = (attrs[:metadata] || {}).merge(
        METADATA_KEY => true,
        REASON_KEY   => REASON,
        AT_KEY       => Time.current.iso8601
      )
      attrs.merge(metadata: metadata)
    end

    private

    # Пустой IP — не первый контакт: без идентификатора подавлять публикацию
    # нельзя, иначе потеряем живого клиента с кривым прокси.
    def first_contact?
      return false if @ip.blank?

      !Inquiry.where(ip_address: @ip).exists?
    end

    # Вердикт фильтра содержимого: булево true или объект с #negative?
    # (результат LLM-фильтра форм). Любой другой вердикт — «прошёл».
    def negative?
      return @classification.negative? if @classification.respond_to?(:negative?)

      @classification == true
    end
  end
end
