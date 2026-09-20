# frozen_string_literal: true

module CrmCards
  # «Этот номер у нас уже был» — подсказка сотруднику в момент ввода телефона.
  #
  # Не запрет: повторное обращение клиента — обычное дело, и решает человек.
  # Но узнать об этом он должен до того, как заполнит карточку и отправит её
  # на модерацию, а не от модератора и не из CRM.
  #
  # Ищем там, где номер клиента лежит нормализованным и осмысленным: заявки с
  # сайта, другие карточки конвейера и стоп-лист. Оценки, отзывы и заказы
  # услуг намеренно не трогаем — там номер часто чужой (звонили «за друга»).
  module PhoneMatches
    LIMIT = 3

    module_function

    # @param digits [String] нормализованный номер (11 цифр, ведущая 7)
    # @param card [CrmCard, nil] карточка, которую сейчас заполняют — её не показываем
    # @return [Array<String>] строки для сообщения, пустой массив — совпадений нет
    def for(digits, card: nil)
      digits = digits.to_s
      return [] unless digits.match?(/\A7\d{10}\z/)

      lines = []
      lines << '⛔ Номер в стоп-листе — звонить нельзя.' if stop_listed?(digits)
      lines.concat(inquiry_lines(digits))
      lines.concat(card_lines(digits, card))
      lines.first(LIMIT + 1)
    end

    def stop_listed?(digits)
      defined?(::PhoneStopList) && ::PhoneStopList.blocked?(digits)
    end

    def inquiry_lines(digits)
      ::Inquiry.where(client_phone_e164: digits).order(created_at: :desc).limit(LIMIT).map do |inquiry|
        # У Inquiry нет обратной связи с лидом — ищем лид по полиморфной ссылке.
        who = ::LeadEvent.find_by(lead_ref: inquiry)&.assigned_to&.mention
        ["📨 Заявка с сайта ##{inquiry.id} от #{Formatters::DateFormat.fmt(inquiry.created_at)}",
         who && "ответственный #{who}"].compact.join(', ')
      end
    end

    # payload — jsonb, поэтому сравниваем по ключам, а не LIKE по всему телу:
    # иначе номер «нашёлся» бы в комментарии к другой карточке.
    def card_lines(digits, card)
      scope = ::CrmCard.where("payload->>'phone' = :d OR payload->>'phone_extra' = :d", d: digits)
      scope = scope.where.not(id: card.id) if card&.id
      scope.order(created_at: :desc).limit(LIMIT).map do |other|
        ["📋 Карточка ##{other.id} (#{::CrmCard::STATUS_LABELS[other.status]})",
         other.responsible&.mention].compact.join(', ')
      end
    end
  end
end
