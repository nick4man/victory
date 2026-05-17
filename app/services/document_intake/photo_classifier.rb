# frozen_string_literal: true

module DocumentIntake
  # Classifies an incoming photo as a known document kind.
  #
  # Strategy (two-layer):
  #   1. YandexVision::Client#classify → label confidence scores
  #      + YandexVision::Client#text_detection → raw OCR text
  #   2. Russian-doc heuristics applied to labels + text
  #   3. Falls back to :other when confidence < CONFIDENCE_THRESHOLD or API unavailable
  #
  # Usage:
  #   DocumentIntake::PhotoClassifier.call(image, uploader: user)
  #   # => :passport | :inn | :egrn | :contract | :other
  #
  # DLP: НИКОГДА не логируем raw OCR text. Только log document_kind result.
  class PhotoClassifier
    CONFIDENCE_THRESHOLD = 0.5

    # Passport heuristics
    PASSPORT_TEXT_RE = /РОССИЙСКАЯ\s+ФЕДЕРАЦИЯ|ПАСПОРТ|РОССИЯ/i.freeze
    PASSPORT_SERIE_RE = /\b\d{2}\s*\d{2}\s+\d{6}\b/.freeze

    # ИНН heuristics
    INN_TEXT_RE = /НАЛОГ|ИНСПЕКЦ|ИНН|СВИДЕТЕЛЬСТВО.*ПОСТАНОВК/i.freeze
    INN_NUMBER_RE = /\b\d{12}\b|\b\d{10}\b/.freeze

    # ЕГРН heuristics
    EGRN_TEXT_RE = /ВЫПИСКА.*ЕГРН|ЕДИНЫЙ.*ГОСУДАРСТВЕННЫЙ.*РЕЕСТР|РОСРЕЕСТР|ОБЪЕКТ.*НЕДВИЖИМОСТИ/i.freeze
    CADASTRAL_RE = /\d{2}:\d{2}:\d{4,7}:\d{1,6}/.freeze

    # Договор heuristics
    CONTRACT_TEXT_RE = /ДОГОВОР\s+(КУПЛИ|АРЕНДЫ|НАЙМА|ИПОТЕКИ)|ПРОДАВЕЦ|ПОКУПАТЕЛЬ|АРЕНДОДАТЕЛЬ|АРЕНДАТОР/i.freeze

    def self.call(image, uploader: nil)
      new(image, uploader: uploader).call
    end

    def initialize(image, uploader: nil)
      @image    = image
      @uploader = uploader
      @client   = YandexVision::Client.new
    end

    # @return [Symbol] :passport | :inn | :egrn | :contract | :other
    def call
      labels = @client.classify(@image) || {}
      ocr    = @client.text_detection(@image) || {}
      text   = ocr['text'].to_s

      kind = detect_kind(labels, text)

      Rails.logger.info(
        "[DocumentIntake::PhotoClassifier] kind=#{kind} " \
        "uploader_id=#{@uploader&.id} labels=#{labels.keys.first(5).inspect}"
      )
      kind
    end

    private

    def detect_kind(labels, text)
      return :passport  if passport?(labels, text)
      return :inn       if inn?(labels, text)
      return :egrn      if egrn?(labels, text)
      return :contract  if contract?(labels, text)

      :other
    end

    def passport?(labels, text)
      doc_confidence = [labels['document'].to_f, labels['id_document'].to_f].max
      face_present   = labels['face'].to_f > 0.4 || labels['person'].to_f > 0.4

      text_match = PASSPORT_TEXT_RE.match?(text) || PASSPORT_SERIE_RE.match?(text)

      (doc_confidence > CONFIDENCE_THRESHOLD && face_present) || text_match
    end

    def inn?(labels, text)
      text_match   = INN_TEXT_RE.match?(text)
      number_match = INN_NUMBER_RE.match?(text)

      text_match && number_match
    end

    def egrn?(labels, text)
      EGRN_TEXT_RE.match?(text) || CADASTRAL_RE.match?(text)
    end

    def contract?(labels, text)
      CONTRACT_TEXT_RE.match?(text)
    end
  end
end
