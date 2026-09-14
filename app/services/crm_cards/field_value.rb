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
    def phone(raw)
      digits = raw.to_s.gsub(/\D/, '')
      digits = "7#{digits}" if digits.length == 10
      digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
      return [nil, 'Нужен российский номер из 11 цифр, начиная с 7 или 8.'] unless digits.match?(/\A7\d{10}\z/)

      [digits, nil]
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
