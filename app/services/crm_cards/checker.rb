# frozen_string_literal: true

module CrmCards
  # Машинная проверка карточки перед модерацией. Модератор должен смотреть на
  # то, что машина проверить не может (правдоподобие, дубли), а не на пустые
  # поля и неверные телефоны.
  #
  # Перепроверка идемпотентна: значения в payload уже нормализованы, а
  # FieldValue.normalize отвечает на них тем же значением.
  class Checker
    def self.call(card)
      new(card).call
    end

    def initialize(card)
      @card = card
      @values = card.payload.to_h
    end

    # @return [Array<Hash{'field' => String, 'message' => String}>]
    def call
      errors = field_errors
      errors.concat(lead_rules) if @card.kind_lead?
      errors.map { |field, message| { 'field' => field, 'message' => message } }
    end

    private

    def field_errors
      Schema.for(@card.kind).filter_map do |field|
        raw = @values[field.key]
        if blank_value?(raw)
          [field.key, 'не заполнено'] if field.required
        else
          _, error = FieldValue.normalize(field, raw)
          [field.key, error] if error
        end
      end
    end

    # Заявка уходит в CRM только после живого контакта ответственного с
    # клиентом — это и отсекает спам с формы сайта.
    def lead_rules
      lead = @card.lead_event
      return [['lead', 'Карточка не привязана к лиду.']] unless lead

      # staff_test здесь намеренно не проверяется: его ставит эвристика
      # StaffSubmissionDetector, в том числе клиенту, чьё имя совпало с именем
      # сотрудника («Ирина»). Запрет по нему навсегда закрыл бы такому клиенту
      # дорогу в CRM — модератор видит пометку в карточке (CardView) и решает сам.
      errors = []
      errors << ['lead', "Лид закрыт (#{lead.current_stage}) — выгружать нечего."] if lead.closed?
      errors << ['lead', 'Лид никому не назначен — сначала назначь ответственного.'] unless lead.assigned?
      if lead.first_contact_at.nil? && lead.current_stage == 'new'
        errors << ['lead', 'С клиентом ещё не связывались: лид на стадии «новый». Свяжись и отметь /stage контакт.']
      end
      crm_id = lead.lead_ref.try(:crm_id)
      errors << ['lead', "Клиент уже в CRM (заявка #{crm_id}) — вторая заявка не нужна."] if crm_id.present?
      errors
    end

    def blank_value?(raw)
      raw.nil? || raw.to_s.strip.empty?
    end
  end
end
