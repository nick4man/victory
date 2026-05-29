# frozen_string_literal: true

module DocumentIntake
  # Extracts structured fields from выписка ЕГРН OCR text.
  #
  # Handles multi-page extracts — pass concatenated OCR text from all pages.
  # Kадастровый номер validation: NN:NN:NNNNNNN:NNNN format.
  #
  # Usage:
  #   DocumentIntake::EgrnParser.call(ocr_text)
  #   # => { cadastral_number: '50:20:0020302:333', area: '54.3', ... }
  #
  # DLP: кадастровый номер — в filter_parameters. Return value must not be
  #   logged raw. Use parsed_data_masked where applicable.
  class EgrnParser
    # Формат кадастрового номера: CC:RR:AAAAAAA:PPPP (субъект:район:квартал:участок)
    CADASTRAL_RE = /\b(\d{2}:\d{2}:\d{6,7}:\d{1,6})\b/.freeze

    # Площадь объекта
    AREA_RE = /(\d+[,.]?\d*)\s*(?:кв\.?\s*м|м²|кв\s*метр)/i.freeze

    # Адрес — стандартные метки ЕГРН
    ADDRESS_LABEL_RE = /(?:Адрес|Местоположение):\s*(.+?)(?=\n[А-ЯЁ]|\z)/m.freeze

    # Правообладатель
    OWNER_LABEL_RE = /(?:Правообладател[ьи]|Собственник):\s*(.+?)(?=\n[А-ЯЁ]|\n\d|\z)/m.freeze

    # Вид права
    RIGHT_TYPE_RE = /(?:Вид права|Вид.*права):\s*(.+?)(?=\n|\z)/.freeze

    # Дата регистрации права
    REG_DATE_RE = /(?:Дата регистрации|Дата.*регистрации)[\s:]+(\d{2}[\.\-]\d{2}[\.\-]\d{4})/.freeze

    # Площадь застройки / жилая площадь
    LIVING_AREA_RE = /(?:Жилая|жилая)\s+площадь[:\s]+(\d+[,.]?\d*)\s*(?:кв\.?\s*м|м²)/i.freeze

    def self.call(ocr_text)
      new(ocr_text).call
    end

    def initialize(ocr_text)
      @text = ocr_text.to_s.strip
    end

    # @return [Hash]
    def call
      {
        cadastral_number: extract_cadastral_number,
        area:             extract_area,
        living_area:      extract_living_area,
        address:          extract_address,
        owner:            extract_owner,
        right_type:       extract_right_type,
        registration_date: extract_registration_date,
        encumbrances:     extract_encumbrances
      }
    end

    private

    def extract_cadastral_number
      m = CADASTRAL_RE.match(@text)
      m ? m[1] : nil
    end

    def extract_area
      m = AREA_RE.match(@text)
      return nil unless m

      # Нормализуем запятую → точку для float-совместимости
      m[1].tr(',', '.')
    end

    def extract_living_area
      m = LIVING_AREA_RE.match(@text)
      return nil unless m

      m[1].tr(',', '.')
    end

    def extract_address
      m = ADDRESS_LABEL_RE.match(@text)
      m ? m[1].strip.gsub(/\s+/, ' ') : nil
    end

    def extract_owner
      m = OWNER_LABEL_RE.match(@text)
      return nil unless m

      owner = m[1].strip.gsub(/\s+/, ' ')
      # Убираем служебные слова после имени собственника
      owner.split(/\n|,/).first&.strip
    end

    def extract_right_type
      m = RIGHT_TYPE_RE.match(@text)
      m ? m[1].strip : nil
    end

    def extract_registration_date
      m = REG_DATE_RE.match(@text)
      return nil unless m

      normalize_date(m[1])
    end

    # Обременения — ищем секцию «Ограничения прав и обременения»
    def extract_encumbrances
      # Если раздел присутствует и содержит «не зарегистрированы» — пусто
      section = @text[/(?:Ограничения|Обременения).{0,200}/m]
      return nil unless section

      no_encumbrances = section.match?(/не\s+зарегистрированы|отсутствуют/i)
      no_encumbrances ? [] : ['present']  # Phase 2: parse kinds of encumbrances
    end

    # Нормализуем дату к ISO для хранения
    def normalize_date(date_str)
      parts = date_str.split(/[\.\-]/)
      return nil if parts.length != 3

      day, month, year = parts
      "#{year}-#{month.rjust(2, '0')}-#{day.rjust(2, '0')}"
    end
  end
end
