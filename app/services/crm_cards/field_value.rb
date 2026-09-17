# frozen_string_literal: true

module CrmCards
  # Нормализация одного значения поля. Контракт [значение, ошибка] — тот же,
  # что у Wizard::Flow#accept, поэтому мастер отдаёт ввод сюда без обёрток.
  #
  # Тексты ошибок не повторяют ввод: Wizard::Engine показывает их без
  # экранирования, и эхо «<b>…» сломало бы разметку сообщения.
  module FieldValue
    module_function

    # @return [Array(Object, String|nil)]
    def normalize(field, raw)
      return [nil, 'Пустое значение.'] if raw.nil? || raw.to_s.strip.empty?

      case field.type
      when :string, :text then text(field, raw)
      when :phone   then phone(raw)
      when :phone_extra then phone(raw, mobile: false)
      when :choice  then choice(field, raw)
      when :integer then integer(raw)
      when :decimal then decimal(raw)
      else [nil, 'Неизвестный тип поля.']
      end
    end

    def text(field, raw)
      value = field.type == :text ? raw.to_s.strip : raw.to_s.squish
      return [nil, "Слишком коротко: #{value.length} симв., нужно от #{field.min}."] if field.min && value.length < field.min
      return [nil, "Слишком длинно: #{value.length} симв., влезает #{field.max}."] if field.max && value.length > field.max

      [value, nil]
    end

    # Topnlab принимает ровно 11 цифр с ведущей 7 (Topnlab::Client#normalize_phone_11d).
    #
    # Мусор из номера вычищаем, но недостачу цифр молча не дорисовываем:
    # «+8ш977842598» — это 10 цифр, и прежний код лепил к ним семёрку, получая
    # несуществующий «+7 897…». Ошибка всплыла бы уже в CRM, на звонке.
    #
    # Первый номер клиента — всегда мобильный (+7 9XX). Городской принимаем
    # только вторым номером (:phone_extra): по нему не перезвонить клиенту,
    # который оставил заявку с сайта, а у российских городских вторая цифра
    # девяткой не бывает — значит, «не 9» после +7 это и есть городской.
    def phone(raw, mobile: true)
      digits = raw.to_s.gsub(/\D/, '')
      # Десять цифр без кода страны: 9 — мобильный, 3/4/8 — код города
      # (495, 4912, 812…). Прочее не дорисовываем: «8977842598» — это опечатка
      # в мобильном, а не номер, которому не хватает семёрки.
      digits = "7#{digits}" if digits.length == 10 && digits.match?(/\A[349]/)
      digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
      unless digits.match?(/\A7\d{10}\z/)
        return [nil, "В номере #{digits.length} цифр, а нужно 11: +7 910 123-45-67 или 89101234567."]
      end
      return [digits, nil] if !mobile || digits[1] == '9'

      [nil, "+7 #{digits[1..3]}… — это не мобильный: после +7 идёт 9. " \
            'Городской номер впиши вторым, в «Доп. телефон».']
    end

    def choice(field, raw)
      value = raw.to_s
      return [value, nil] if Array(field.options).any? { |_, v| v == value }

      [nil, 'Такого варианта нет — выбери кнопкой.']
    end

    def integer(raw)
      value = raw.to_s.strip
      return [nil, 'Нужно целое число цифрами.'] unless value.match?(/\A\d+\z/)
      return [nil, 'Число должно быть больше нуля.'] if value.to_i.zero?

      [value.to_i, nil]
    end

    def decimal(raw)
      value = raw.to_s.delete("  ").tr(',', '.') # пробел и неразрывный пробел: «5 500 000» из Telegram
      return [nil, 'Нужно число цифрами, например 54,3.'] unless value.match?(/\A\d+(\.\d+)?\z/)

      number = value.to_f.round(2)
      return [nil, 'Число должно быть больше нуля.'] unless number.positive?

      [(number % 1).zero? ? number.to_i : number, nil]
    end
  end
end
