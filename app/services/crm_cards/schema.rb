# frozen_string_literal: true

module CrmCards
  # Поля карточек — ровно то, что можно выгрузить в CRM, и ничего сверх.
  # Поле, которое некуда отправить, сотрудник заполнял бы зря.
  #
  # LEAD повторяет параметры Topnlab::Client#import_client.
  module Schema
    # rubocop:disable Lint/StructNewOverride -- :min/:max — границы поля (контракт из брифа), не Struct#min/#max
    Field = Struct.new(:key, :label, :type, :required, :options, :hint, :min, :max, keyword_init: true)
    # rubocop:enable Lint/StructNewOverride

    ACTIONS = [['Продажа / покупка', 'sale'], ['Аренда', 'rent']].freeze
    REALTY_TYPES = [
      %w[Квартира flat], %w[Комната room], %w[Дом house],
      %w[Коммерция commerce], %w[Участок land], %w[Гараж garage]
    ].freeze
    PHONE_HINT = 'Российский номер: +7 910 123-45-67 или 89101234567.'

    LEAD = [
      Field.new(key: 'name', label: 'Имя клиента', type: :string, required: true, max: 255),
      Field.new(key: 'phone', label: 'Телефон', type: :phone, required: true, hint: PHONE_HINT),
      Field.new(key: 'action', label: 'Что нужно клиенту', type: :choice, required: true, options: ACTIONS),
      Field.new(key: 'object_type', label: 'Тип объекта', type: :choice, required: true, options: REALTY_TYPES),
      Field.new(key: 'comment', label: 'Итог разговора с клиентом', type: :text, required: true, min: 20, max: 500,
                hint: 'Что ищет, бюджет, сроки. Это подтверждение, что с клиентом говорили: ' \
                      'без итога разговора карточка на модерацию не уйдёт.'),
      Field.new(key: 'realty_id', label: 'ID объекта в CRM', type: :integer, required: false,
                hint: 'Если клиент звонил по конкретному объекту — номер его карточки в Topnlab.')
    ].freeze

    KINDS = { 'lead' => LEAD }.freeze

    module_function

    # @raise [KeyError] на неизвестном виде карточки
    def for(kind)
      KINDS.fetch(kind.to_s)
    end

    def field(kind, key)
      self.for(kind).find { |f| f.key == key.to_s }
    end

    def option_label(field, value)
      Array(field.options).find { |_, v| v == value.to_s }&.first
    end
  end
end
