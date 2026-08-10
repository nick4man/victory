# frozen_string_literal: true

module Crm
  # Разбор контакта собственника, присланного агентом в телеграм.
  #
  # Два входа. Первый — пересланная карточка контакта: Telegram отдаёт готовые
  # поля, разбирать почти нечего. Второй — свободный текст, потому что половина
  # людей пришлёт «Светлана 9001234567» вместо карточки, и требовать от агента
  # строгий формат значит получить ноль ответов.
  #
  #   Crm::ContactParser.from_telegram(msg['contact'])
  #   Crm::ContactParser.from_text('Светлана Петрова +7 900 123-45-67 s@mail.ru')
  #   # => { first_name:, last_name:, phone:, email: } либо nil, если контакта нет
  class ContactParser
    EMAIL_RE = /\b[\w.+-]+@[\w-]+\.[\w.-]+\b/
    # Российский номер в любом бытовом виде: +7, 8, со скобками, дефисами,
    # пробелами. Требуем не меньше 10 цифр подряд с разделителями, иначе в
    # телефон превратится любое число из описания объекта.
    PHONE_RE = /(?:\+?[78][\s\-()]*)?\(?\d{3}\)?[\s\-]?\d{3}[\s\-]?\d{2}[\s\-]?\d{2}\b/

    # Слова, которые агент пишет вокруг контакта — в имя они попасть не должны.
    NOISE = /\A(?:собственник|владелец|хозяин|клиент|это|тел|телефон|моб|номер|почта|email|e-mail)\z/i

    class << self
      # @param contact [Hash, nil] объект contact из Telegram-сообщения
      def from_telegram(contact)
        return nil unless contact.is_a?(Hash)

        phone = contact['phone_number'].to_s.strip.presence
        return nil if phone.blank?

        {
          first_name: contact['first_name'].to_s.strip.presence,
          last_name: contact['last_name'].to_s.strip.presence,
          phone: phone,
          email: nil
        }
      end

      # @param text [String, nil]
      # @return [Hash, nil] nil, когда ни телефона, ни email в тексте нет —
      #   заводить клиента не из чего, и лучше переспросить, чем создать пустышку
      def from_text(text)
        raw = text.to_s
        return nil if raw.blank?

        email = raw[EMAIL_RE]
        phone = extract_phone(raw)
        return nil if email.blank? && phone.blank?

        first, last = extract_name(raw, email, phone)
        { first_name: first, last_name: last, phone: phone, email: email }
      end

      private

      def extract_phone(raw)
        # Кандидатов может быть несколько (например, номер в адресе дома) —
        # берём первый, в котором ровно 10 или 11 значащих цифр.
        raw.scan(PHONE_RE).find do |candidate|
          digits = candidate.gsub(/\D/, '')
          digits.length.between?(10, 11)
        end&.strip
      end

      # Имя — то, что осталось от текста после вырезания контактов и служебных
      # слов. Разбор именно такой, а не «первое слово»: агент пишет и «Светлана
      # 9001234567», и «собственник — Пётр Иванович, тел …».
      def extract_name(raw, email, phone)
        rest = raw.dup
        rest = rest.sub(email, ' ') if email
        rest = rest.sub(phone, ' ') if phone

        words = rest.split(/[\s,;:—–-]+/)
                    .map { |w| w.gsub(/[^[:alpha:]\-']/, '') }
                    .reject { |w| w.blank? || w.match?(NOISE) || w.length < 2 }

        [words[0], words[1]]
      end
    end
  end
end
