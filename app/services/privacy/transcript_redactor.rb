# frozen_string_literal: true

module Privacy
  # Phase 7.7 — DLP-маскирование PII в text-транскриптах перед сохранением.
  #
  # Применяется в VoiceTranscriber pipeline (Phase 7.1) — НИКОГДА не храним
  # unredacted транскрипт в БД/логах. Также используется для outbound DM
  # (Вася получает «позвонить клиенту [PHONE]», а не полный номер).
  #
  # Паттерны (РФ-специфика):
  #   • Phone — `+7|8` + 10 цифр в разных форматах (пробелы/тире/скобки/dot)
  #   • Passport РФ — 4 цифры + 6 цифр («4521 123456» / «45 21 123456» / «4521-123456»)
  #   • INN — 10 цифр (юр.лицо) или 12 цифр (ИП/физлицо)
  #   • Email — стандартный pattern
  #
  # Каждый pattern заменяется на токен `[PHONE]` / `[PASSPORT]` / `[INN]` / `[EMAIL]`.
  # Это сохраняет читаемость текста — Вася понимает что «позвонить [PHONE]»
  # значит звонок (контакт — в карточке лида / Topnlab CRM, не в transcript).
  #
  # @example
  #   Privacy::TranscriptRedactor.call("Васе позвонить +7 (999) 123-45-67 до 16:00")
  #   # => "Васе позвонить [PHONE] до 16:00"
  #
  #   Privacy::TranscriptRedactor.call("Паспорт 4521 123456, ИНН 123456789012")
  #   # => "Паспорт [PASSPORT], ИНН [INN]"
  class TranscriptRedactor
    # === Phone (РФ) ===
    # Покрывает: +7 999 123 45 67 / +7(999)123-45-67 / 8 999 1234567 /
    #            +7-999-123-45-67 / 89991234567 / 7 999 123 4567
    # Не покрывает: международные не-РФ номера (отдельный кейс если понадобится).
    PHONE_RE = /
      (?<!\d)                     # граница слева (не цифра)
      (?:\+?7|8)                    # код страны
      [\s\-().]*                    # разделитель
      9\d{2}                        # 9XX
      [\s\-().]*
      \d{3}                         # XXX
      [\s\-().]*
      \d{2}                         # XX
      [\s\-().]*
      \d{2}                         # XX
      (?!\d)                      # граница справа
    /x

    # === Passport РФ === Серия 4 цифры + номер 6 цифр.
    # Допускаем 2+2 формат серии («45 21 123456»).
    PASSPORT_RE = /
      (?<!\d)
      \d{2}[\s-]?\d{2}             # серия 4 цифры (с опц. разделителем 2+2)
      [\s-]+                       # обязательный разделитель серии и номера
      \d{6}                         # номер 6 цифр
      (?!\d)
    /x

    # === INN === 10 цифр (юрлицо) или 12 (ИП/физлицо). Word-boundary важна
    # чтобы не цепляться к длинным номерам типа сделки/лота.
    INN_RE = /
      (?<!\d)
      (?:\d{12}|\d{10})
      (?!\d)
    /x

    # === Email === простой паттерн, достаточный для воле речевой транскрипции.
    EMAIL_RE = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/

    # === SNILS (Phase 9 Iter 2) === 11 цифр в формате NNN-NNN-NNN NN
    # или slim NNNNNNNNNNN. Контрольная сумма не проверяется (для DLP не критично).
    SNILS_RE = /
      (?<!\d)
      \d{3}[\s-]?\d{3}[\s-]?\d{3}[\s-]?\d{2}
      (?!\d)
    /x

    # === Passport SERIES alone (Phase 9 Iter 2) === Серия из 4 цифр БЕЗ номера
    # после неё («серия 4521»). Имеет lookahead "не цифра" чтобы не двигать
    # PASSPORT_RE (где серия + номер). Регистронечувствительный keyword guard.
    PASSPORT_SERIES_RE = /(?:серия|серии|сер\.?)\s*(\d{2}[\s-]?\d{2})\b(?!\s*\d{6})/i

    # Порядок важен:
    #   • EMAIL первым — alphanum, не пересекается
    #   • PHONE — может быть прочитан как INN если короткий
    #   • PASSPORT (серия+номер) — длиннее SNILS, должен идти первым из числовых docs
    #   • SNILS — 11 цифр с дефисами; не пересекается с PASSPORT (там есть [\s-]+ между серией и номером, но pattern requires 4+6 а не 3+3+3+2)
    #   • PASSPORT_SERIES — keyword guard, поэтому после общих numeric
    #   • INN — последним (10/12 цифр)
    PATTERNS = [
      [EMAIL_RE,           '[EMAIL]'],
      [PHONE_RE,           '[PHONE]'],
      [PASSPORT_RE,        '[PASSPORT]'],
      [SNILS_RE,           '[SNILS]'],
      [PASSPORT_SERIES_RE, 'серия [SERIES]'],
      [INN_RE,             '[INN]']
    ].freeze

    def self.call(text)
      new(text).call
    end

    def initialize(text)
      @text = text.to_s
    end

    def call
      return '' if @text.empty?

      PATTERNS.reduce(@text) { |acc, (re, token)| acc.gsub(re, token) }
    end
  end
end
