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
    PHONE_HINT = 'Мобильный клиента: +7 910 123-45-67 или 89101234567. Городской — вторым номером.'

    LEAD = [
      Field.new(key: 'name', label: 'Имя клиента', type: :string, required: true, max: 255),
      Field.new(key: 'phone', label: 'Телефон', type: :phone, required: true, hint: PHONE_HINT),
      Field.new(key: 'phone_extra', label: 'Доп. телефон', type: :phone_extra, required: false,
                hint: 'Второй номер клиента: городской или ещё один мобильный. Нет — пропусти.'),
      Field.new(key: 'action', label: 'Что нужно клиенту', type: :choice, required: true, options: ACTIONS),
      Field.new(key: 'object_type', label: 'Тип объекта', type: :choice, required: true, options: REALTY_TYPES),
      Field.new(key: 'comment', label: 'Итог разговора с клиентом', type: :text, required: true, min: 20, max: 500,
                hint: 'Что ищет, бюджет, сроки. Это подтверждение, что с клиентом говорили: ' \
                      'без итога разговора карточка на модерацию не уйдёт.'),
      Field.new(key: 'realty_id', label: 'ID объекта в CRM', type: :integer, required: false,
                hint: 'Если клиент звонил по конкретному объекту — номер его карточки в Topnlab.')
    ].freeze

    CONTRACT_TYPES = [
      ['Агентский договор', 'agent'], ['Соглашение на рекламу', 'ad_agreement'], ['Устная договорённость', 'verbal']
    ].freeze

    # Минимум формы «Создать объект Продавца» (ТЗ плагина topnlab-crm, §6) для
    # ручного внесения. Порядок важен: условно обязательные поля (комнаты,
    # площадь участка, номер договора) идут после тех, от которых зависят, —
    # мастер решает, спрашивать ли их, по уже данным ответам.
    OBJECT = [
      Field.new(key: 'owner_name', label: 'Собственник', type: :string, required: true, max: 255),
      Field.new(key: 'owner_phone', label: 'Телефон собственника', type: :phone, required: true, hint: PHONE_HINT),
      Field.new(key: 'action', label: 'Сделка', type: :choice, required: true, options: ACTIONS),
      Field.new(key: 'realty_type', label: 'Тип объекта', type: :choice, required: true, options: REALTY_TYPES),
      Field.new(key: 'address', label: 'Адрес', type: :string, required: true, min: 10, max: 255,
                hint: 'Населённый пункт, улица, дом — как в документах.'),
      Field.new(key: 'price', label: 'Цена, ₽', type: :decimal, required: true),
      Field.new(key: 'area_common', label: 'Общая площадь, м²', type: :decimal, required: false),
      Field.new(key: 'area_living', label: 'Жилая площадь, м²', type: :decimal, required: false),
      Field.new(key: 'area_kitchen', label: 'Кухня, м²', type: :decimal, required: false),
      Field.new(key: 'area_land', label: 'Участок, сот.', type: :decimal, required: false),
      Field.new(key: 'rooms', label: 'Комнат', type: :integer, required: false),
      Field.new(key: 'floor', label: 'Этаж', type: :integer, required: false),
      Field.new(key: 'floors_total', label: 'Этажей в доме', type: :integer, required: false),
      Field.new(key: 'contract_type', label: 'Договор с собственником', type: :choice, required: true,
                options: CONTRACT_TYPES),
      Field.new(key: 'contract_number', label: 'Номер договора', type: :string, required: false, max: 64),
      Field.new(key: 'comment', label: 'Комментарий', type: :text, required: false, max: 1000)
    ].freeze

    KINDS = { 'lead' => LEAD, 'object' => OBJECT }.freeze

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
