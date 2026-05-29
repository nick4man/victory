# frozen_string_literal: true

module DocumentIntake
  # Extracts structured fields from Russian passport OCR text.
  #
  # Usage:
  #   DocumentIntake::PassportParser.call(ocr_text)
  #   # => { passport_series: '1234', passport_number: '567890',
  #   #       last_name: 'ИВАНОВ', ... }
  #
  # Each field returns nil если regex no match / text too ambiguous.
  # `confidence` in returned hash = rough field-level quality signal
  # (1.0 = all mandatory fields present, 0.x = partial).
  #
  # DLP: caller must NOT log the return value directly — use
  #   ClientDocument#parsed_data_masked for any UI/notification.
  class PassportParser
    # ── Regexes ──────────────────────────────────────────────────────────────
    PASSPORT_FIELD_REGEXES = {
      # «12 34 567890» или «1234 567890» или «12 34  567890»
      series_number: /\b(\d{2})\s*(\d{2})\s{1,3}(\d{6})\b/,

      # Дата в форматах dd.mm.yyyy / dd-mm-yyyy / dd mm yyyy
      date:          /\b(\d{2})[\.\-\s](\d{2})[\.\-\s](\d{4})\b/,

      # Код подразделения NNN-NNN
      issue_code:    /\b(\d{3})-(\d{3})\b/,

      # Всё в верхнем регистре на кириллице — потенциальное ФИО/место
      caps_cyrillic: /\b([А-ЯЁ]{2,}(?:\s+[А-ЯЁ]{2,})*)\b/,

      # «ВЫДАН» / «ВЫДАНО» метка перед именем органа
      issued_marker: /(?:ВЫД(?:АН|АНО|АНА))[\s\n]+(.+?)(?=\n|\d{2}[\.\-]\d{2}|\z)/m,

      # Место рождения — после метки
      birthplace_marker: /(?:МЕСТО\s+РОЖДЕНИЯ|М\.?\s*РОЖДЕНИЯ)[\s\n:]+(.+?)(?=\n[А-ЯЁ]{3,}|\z)/m
    }.freeze

    def self.call(ocr_text)
      new(ocr_text).call
    end

    def initialize(ocr_text)
      @text = ocr_text.to_s.strip
    end

    # @return [Hash]
    def call
      result = {
        passport_series:  extract_series,
        passport_number:  extract_number,
        last_name:        extract_last_name,
        first_name:       extract_first_name,
        middle_name:      extract_middle_name,
        birth_date:       extract_birth_date,
        birth_place:      extract_birth_place,
        issued_by:        extract_issued_by,
        issue_date:       extract_issue_date,
        issue_code:       extract_issue_code
      }

      result[:confidence] = compute_confidence(result)
      result
    end

    private

    # ── Series & Number ───────────────────────────────────────────────────────

    def series_number_match
      @series_number_match ||= PASSPORT_FIELD_REGEXES[:series_number].match(@text)
    end

    def extract_series
      m = series_number_match
      return nil unless m

      "#{m[1]}#{m[2]}"
    end

    def extract_number
      m = series_number_match
      return nil unless m

      m[3]
    end

    # ── ФИО ──────────────────────────────────────────────────────────────────
    # Паспорт РФ: строка ФАМИЛИЯ, строка ИМЯ, строка ОТЧЕСТВО идут последовательно
    # в строгом порядке ПОСЛЕ серия+номер.
    #
    # Алгоритм:
    #   1. Найти позицию серия+номер в тексте
    #   2. Сканировать строки только ПОСЛЕ этой позиции
    #   3. Взять первые 3 строки целиком из капс-кириллицы (фамилия + имя + отчество)
    #
    # Стоп-слова (заголовки паспорта) исключаются — они ВСЕГДА идут до серии/номера.

    KNOWN_KEYWORDS = %w[
      ПАСПОРТ РОССИЙСКАЯ ФЕДЕРАЦИЯ РОССИЯ ПОЛИЦИЯ МВД УФМС
      ВЫДАН ВЫДАНО ВЫДАНА МЕСТО РОЖДЕНИЯ РОЖДЕНИЯ
    ].freeze

    def fio_lines
      return @fio_lines if defined?(@fio_lines)

      # Текст начиная с позиции ПОСЛЕ серия+номер
      text_after_serie = if series_number_match
                           @text[series_number_match.end(0)..]&.to_s || ''
                         else
                           @text
                         end

      @fio_lines = text_after_serie
        .scan(/^([А-ЯЁ\-]{2,})$/)
        .flatten
        .reject { |word| KNOWN_KEYWORDS.include?(word) }
        .first(3)
    end

    def extract_last_name
      fio_lines[0]
    end

    def extract_first_name
      fio_lines[1]
    end

    def extract_middle_name
      fio_lines[2]
    end

    # ── Даты ─────────────────────────────────────────────────────────────────
    # В паспорте обычно 2 даты: дата рождения + дата выдачи.
    # Дата рождения идёт первой в тексте (страница с фото).

    def all_dates
      return @all_dates if defined?(@all_dates)

      @all_dates = @text.scan(PASSPORT_FIELD_REGEXES[:date]).map do |d, m, y|
        # Нормализуем к ISO для хранения; UI рендерит через dd.MM.yy helper
        "#{y}-#{m.rjust(2, '0')}-#{d.rjust(2, '0')}"
      end
    end

    def extract_birth_date
      all_dates[0]
    end

    def extract_issue_date
      all_dates[1]
    end

    # ── Место рождения ────────────────────────────────────────────────────────

    def extract_birth_place
      m = PASSPORT_FIELD_REGEXES[:birthplace_marker].match(@text)
      m ? m[1].strip.gsub(/\s+/, ' ') : nil
    end

    # ── Кем выдан ─────────────────────────────────────────────────────────────

    def extract_issued_by
      m = PASSPORT_FIELD_REGEXES[:issued_marker].match(@text)
      m ? m[1].strip.gsub(/\s+/, ' ') : nil
    end

    # ── Код подразделения ─────────────────────────────────────────────────────

    def extract_issue_code
      m = PASSPORT_FIELD_REGEXES[:issue_code].match(@text)
      m ? "#{m[1]}-#{m[2]}" : nil
    end

    # ── Confidence ────────────────────────────────────────────────────────────
    # Mandatories: series, number, last_name, first_name, birth_date (5 fields).
    # +1 optional each for middle_name, issued_by, issue_date, issue_code.

    MANDATORY_FIELDS = %i[passport_series passport_number last_name first_name birth_date].freeze

    def compute_confidence(result)
      mandatory_present = MANDATORY_FIELDS.count { |f| result[f].present? }
      base = mandatory_present.to_f / MANDATORY_FIELDS.size

      optional_present = %i[middle_name issued_by issue_date issue_code].count { |f| result[f].present? }
      bonus = optional_present * 0.025  # max +0.1 от опциональных

      [base + bonus, 1.0].min.round(3)
    end
  end
end
