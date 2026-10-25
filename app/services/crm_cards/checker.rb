# frozen_string_literal: true

module CrmCards
  # Машинная проверка карточки перед модерацией. Модератор должен смотреть на
  # то, что машина проверить не может (правдоподобие, дубли), а не на пустые
  # поля и неверные телефоны.
  #
  # Перепроверка идемпотентна: значения в payload уже нормализованы, а
  # FieldValue.normalize отвечает на них тем же значением.
  class Checker
    CONDITIONAL_MESSAGES = {
      'area_common' => 'не заполнено — для этого типа объекта нужна общая площадь',
      'area_land' => 'не заполнено — для участка нужна площадь участка',
      'rooms' => 'не заполнено — для квартиры укажи число комнат',
      'contract_number' => 'не заполнено — для агентского договора и соглашения на рекламу нужен номер договора'
    }.freeze

    def self.call(card)
      new(card).call
    end

    # Поля объекта, обязательные при данных значениях других полей. Нужны и
    # проверке, и мастеру: он спрашивает эти поля, а прочие необязательные
    # оставляет на «Изменить поле».
    # @return [Array<String>]
    def self.conditionally_required(values)
      type = values['realty_type'].to_s
      keys = []
      keys << (type == 'land' ? 'area_land' : 'area_common') if type.present?
      keys << 'rooms' if type == 'flat'
      keys << 'contract_number' if %w[agent ad_agreement].include?(values['contract_type'].to_s)
      keys
    end

    def initialize(card)
      @card = card
      @values = card.payload.to_h
    end

    # @return [Array<Hash{'field' => String, 'message' => String}>]
    def call
      errors = field_errors
      errors.concat(lead_rules) if @card.kind_lead?
      errors.concat(object_rules) if @card.kind_object?
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

    # Правила формы CRM (ТЗ плагина, §6): общая площадь не меньше жилой и
    # кухни, этаж не выше дома, номер обязателен для договоров с подписью.
    def object_rules
      errors = self.class.conditionally_required(@values).filter_map do |key|
        [key, CONDITIONAL_MESSAGES.fetch(key)] if blank_value?(@values[key])
      end
      common, living, kitchen = @values.values_at('area_common', 'area_living', 'area_kitchen').map(&:to_f)
      if common.positive? && living + kitchen > common
        errors << ['area_common',
                   "Общая площадь #{area(common)} м² меньше суммы жилой и кухни (#{area(living + kitchen)} м²)."]
      end
      floor, total = @values.values_at('floor', 'floors_total').map(&:to_i)
      errors << ['floor', "Этаж #{floor} выше этажности дома (#{total})."] if floor.positive? && total.positive? && floor > total
      errors
    end

    def area(value)
      ActiveSupport::NumberHelper.number_to_rounded(value, precision: 2, strip_insignificant_zeros: true, separator: ',')
    end

    def blank_value?(raw)
      raw.nil? || raw.to_s.strip.empty?
    end
  end
end
