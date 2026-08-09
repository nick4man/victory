# frozen_string_literal: true

module DocumentIntake
  # Extracts and validates ИНН from OCR text.
  #
  # Supports:
  #   - 12-digit INN (физическое лицо — individual)
  #   - 10-digit INN (юридическое лицо — legal entity)
  #
  # Validates check-digit per ФНС algorithm (ГОСТ Р 34.10).
  # Returns nil for inn field if check-digit fails — don't blindly trust OCR.
  #
  # Usage:
  #   DocumentIntake::InnParser.call(ocr_text)
  #   # => { inn: '123456789012', inn_type: 'individual', full_name: 'ИВАНОВ ИВАН ИВАНОВИЧ' }
  #
  # DLP: return value must NEVER be logged raw. Use ClientDocument#mask_inn.
  class InnParser
    # Capture standalone 10 or 12-digit sequences
    INN_RE    = /\b(\d{12})\b|\b(\d{10})\b/.freeze
    # ФИО ищем построчно: строка целиком из 2-3 слов, каждое с заглавной и
    # длиной от двух букв.
    #
    # Прежний вариант требовал Title Case ([А-ЯЁ][а-яё]+) и потому НИКОГДА не
    # срабатывал на реальных документах: ОСR свидетельства ФНС отдаёт «ИВАНОВ
    # ИВАН ИВАНОВИЧ» капсом — ровно так, как показано в примере в шапке этого
    # класса. full_name молча возвращался nil.
    #
    # Якоря \A..\z по строке отсекают боилерплейт: «СВИДЕТЕЛЬСТВО О ПОСТАНОВКЕ
    # НА УЧЁТ» — пять слов, «ИНН 500100732259» — цифры, односимвольные предлоги
    # не проходят порог в две буквы.
    FIO_RE    = /\A[А-ЯЁ][А-ЯЁа-яё-]+(?:\s+[А-ЯЁ][А-ЯЁа-яё-]+){1,2}\z/.freeze

    # Weights for 12-digit INN check digits (ФНС algorithm)
    WEIGHTS_11 = [7, 2, 4, 10, 3, 5, 9, 4, 6, 8].freeze
    WEIGHTS_12 = [3, 7, 2, 4, 10, 3, 5, 9, 4, 6, 8].freeze

    # Weights for 10-digit INN (legal entity)
    WEIGHTS_10 = [2, 4, 10, 3, 5, 9, 4, 6, 8].freeze

    def self.call(ocr_text)
      new(ocr_text).call
    end

    def initialize(ocr_text)
      @text = ocr_text.to_s.strip
    end

    # @return [Hash]
    def call
      inn, inn_type = extract_validated_inn
      full_name     = extract_full_name

      {
        inn:       inn,
        inn_type:  inn_type,
        full_name: full_name
      }
    end

    private

    def extract_validated_inn
      candidates = @text.scan(INN_RE).flatten.compact

      candidates.each do |candidate|
        digits = candidate.gsub(/\D/, '')
        next if digits.length != 12 && digits.length != 10

        if digits.length == 12
          return [digits, 'individual'] if valid_individual_inn?(digits)
        else
          return [digits, 'legal'] if valid_legal_inn?(digits)
        end
      end

      # Если контрольное число не сошлось — возвращаем первый найденный как unvalidated
      # (confidence будет низкий, human review подхватит)
      raw = candidates.first
      return [nil, nil] if raw.nil?

      digits = raw.gsub(/\D/, '')
      inn_type = digits.length == 12 ? 'individual' : 'legal'
      [digits, inn_type]
    end

    # ── ФНС check-digit algorithm ─────────────────────────────────────────────
    #
    # Физлицо (12 цифр):
    #   11-й разряд = (сумма d[0..9] * WEIGHTS_11) % 11 % 10
    #   12-й разряд = (сумма d[0..10] * WEIGHTS_12) % 11 % 10

    def valid_individual_inn?(digits)
      d = digits.chars.map(&:to_i)

      check11 = weighted_sum(d[0, 10], WEIGHTS_11) % 11 % 10
      check12 = weighted_sum(d[0, 11], WEIGHTS_12) % 11 % 10

      d[10] == check11 && d[11] == check12
    end

    # Юрлицо (10 цифр):
    #   10-й разряд = (сумма d[0..8] * WEIGHTS_10) % 11 % 10

    def valid_legal_inn?(digits)
      d = digits.chars.map(&:to_i)

      check10 = weighted_sum(d[0, 9], WEIGHTS_10) % 11 % 10
      d[9] == check10
    end

    def weighted_sum(digits, weights)
      digits.zip(weights).sum { |d, w| d * w }
    end

    def extract_full_name
      @text.to_s.each_line do |line|
        candidate = line.strip
        return candidate if FIO_RE.match?(candidate)
      end
      nil
    end
  end
end
