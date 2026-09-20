# frozen_string_literal: true

module CrmCards
  # «Вставил как есть» — разбор произвольного текста о клиенте в поля карточки.
  #
  # Сотрудник копирует переписку, письмо или заметку и вставляет одним
  # сообщением; мастер дальше спрашивает только то, чего в тексте не нашлось.
  #
  # Сначала правила, и только если после них не хватает обязательного — LLM.
  # Порядок именно такой: телефон и тип сделки правила берут надёжнее модели,
  # а каждый вызов модели в проде стоит денег (цепочки переопределены в .env).
  # Любое значение, откуда бы оно ни пришло, проходит FieldValue.normalize:
  # выдуманный моделью телефон в карточку не попадёт.
  class TextIntake
    MIN_TEXT = 12
    MAX_TEXT = 4000

    # rubocop:disable Lint/StructNewOverride -- :values здесь поля карточки, Struct#values не используем
    Result = Struct.new(:values, :model, :error, keyword_init: true) do
      def any? = values.present?
    end
    # rubocop:enable Lint/StructNewOverride

    ACTION_WORDS = {
      'rent' => /аренд|сним|снять|сда[ёе]|сдать|съ[её]м|на[ёе]м/i,
      'sale' => /куп|прода|покуп|ипотек|сделк/i
    }.freeze

    # Порядок важен: «однокомнатная» — это квартира, а не комната, поэтому
    # квартиру проверяем раньше, а комнату ловим только по началу слова.
    # «дом» — обязательно с начала слова, иначе «рядом с лесом» становится домом.
    REALTY_WORDS = {
      'flat' => /квартир|студи|однушк|двушк|тр[её]шк|\d\s*-?\s*комн|[а-я]+комнатн/i,
      'room' => /\bкомнат/i,
      'house' => /\bдом[ауе]?\b|коттедж|таунхаус|дача/i,
      'commerce' => /коммерц|офис|склад|помещени|торгов/i,
      'land' => /участок|земл|сотк/i,
      'garage' => /гараж|машиноместо/i
    }.freeze

    NAME_LABEL = /(?:фио|имя|клиент|контакт|собственник)\s*[:\-—]\s*(.+)/i
    # Имя без подписи — минимум два слова с заглавной в начале строки
    # («Анна Смирнова», «Пётр Иванов 8910…»). Одно слово не берём: «Сдаёт»,
    # «Хочет», «Звонил» с заглавной выглядят так же, как имя.
    NAME_LINE = /\A\s*([[:upper:]][[:alpha:]-]+(?:\s+[[:upper:]][[:alpha:]-]+){1,2})(?=[\s,.;:!?]|\z)/
    REALTY_ID = /(?:объект|объекта|id|ид|лот|№)\s*[:#]?\s*(\d{3,9})/i
    # Разделители внутри номера — что угодно, кроме перевода строки: иначе номер
    # в конце строки слипается с цифрами следующей, выходит 12 цифр, проверка
    # их отбрасывает, и телефон пропадает молча.
    PHONE_CANDIDATE = /(?:\+?\d[ \t\u00a0()\-]*){10,}/

    def self.call(kind:, text:, client: nil, llm: true, needs: nil)
      new(kind: kind, text: text, client: client, llm: llm, needs: needs).call
    end

    # llm: false — только правила. Так текст разбирают повторно (уже сохранённый
    # у лида), и платить за модель второй раз не за что.
    #
    # needs — поля, ради которых стоит звать модель. По умолчанию все обязательные
    # в карточке, но зовущему они нужны не всегда: тестовому мастеру хватает имени
    # с телефоном, и без этого списка он платил бы за модель на каждой вставке.
    def initialize(kind:, text:, client: nil, llm: true, needs: nil)
      @kind = kind.to_s
      @text = text.to_s.strip.first(MAX_TEXT).to_s
      @client = client
      @llm = llm
      @needs = needs&.map(&:to_s)
    end

    def call
      return Result.new(values: {}, error: 'Текст слишком короткий — вставь данные клиента целиком.') if too_short?

      values = normalize(rules)
      return Result.new(values: values) if !@llm || missing_required(values).empty?

      llm = llm_values
      Result.new(values: normalize(llm.fetch(:values, {}).merge(values)), model: llm[:model], error: llm[:error])
    end

    private

    def too_short? = @text.length < MIN_TEXT

    def schema = Schema.for(@kind)

    def missing_required(values)
      keys = @needs || schema.select(&:required).map(&:key)
      keys.select { |key| values[key].blank? }
    end

    # Значение остаётся, только если проходит обычную проверку поля.
    def normalize(raw_values)
      schema.each_with_object({}) do |field, acc|
        raw = raw_values[field.key]
        next if raw.blank?

        value, error = FieldValue.normalize(field, raw)
        acc[field.key] = value if error.nil?
      end
    end

    def rules
      values = {}
      phones = phone_digits
      values[key(:phone)] = phones.first if phones.first
      values[key(:phone_extra)] = phones[1] if phones[1] && key(:phone_extra)
      values[key(:name)] = name if name
      values['action'] = action
      values[key(:realty)] = REALTY_WORDS.find { |_, re| @text.match?(re) }&.first
      values['realty_id'] = @text[REALTY_ID, 1] if @kind == 'lead'
      values['comment'] = comment if @kind == 'lead'
      values.compact
    end

    # Совпали обе стороны сделки — не угадываем: «сейчас снимает, хочет купить»
    # одинаково похоже на аренду и на покупку. Пустое поле мастер спросит,
    # а неверно угаданное само же свой вопрос и погасит.
    def action
      matched = ACTION_WORDS.select { |_, re| @text.match?(re) }.keys
      matched.first if matched.one?
    end

    # Вставка длиннее лимита поля иначе не прошла бы проверку и молча пропала,
    # а следом — платный вызов модели за «недостающее» обязательное поле.
    # Дословную копию всей вставки в «итог разговора» не кладём: ФИО и телефон
    # уже разложены по своим полям, и дублировать их в заметке незачем —
    # модератор читает одно и то же трижды.
    def comment
      limit = schema.find { |f| f.key == 'comment' }&.max
      text = @text.gsub(PHONE_CANDIDATE, ' ').gsub(NAME_LABEL, ' ').squish
      text = @text.squish if text.length < MIN_TEXT
      limit ? text.truncate(limit) : text
    end

    # Одно и то же по смыслу поле называется в заявке и в объекте по-разному.
    KEYS = {
      'lead' => { name: 'name', phone: 'phone', phone_extra: 'phone_extra', realty: 'object_type' },
      'object' => { name: 'owner_name', phone: 'owner_phone', phone_extra: nil, realty: 'realty_type' }
    }.freeze

    def key(role) = KEYS.fetch(@kind, KEYS['lead'])[role]

    def name
      labelled = @text[NAME_LABEL, 1]&.squish
      return labelled if labelled.present?

      @text.lines.filter_map { |line| line[NAME_LINE, 1]&.squish }.find { |candidate| candidate.length > 2 }
    end

    # Телефоны в порядке появления: первый мобильный — основной, следующий — доп.
    def phone_digits
      @text.scan(PHONE_CANDIDATE).filter_map do |candidate|
        digits, error = FieldValue.phone(candidate, mobile: false)
        digits if error.nil?
      end.uniq.sort_by { |d| d[1] == '9' ? 0 : 1 }
    end

    def llm_values
      response = client.complete(
        [{ role: 'system', content: system_prompt }, { role: 'user', content: @text }],
        chain: :analysis, max_tokens: 400, temperature: 0.1, response_format: { type: 'json_object' }
      )
      parsed = JSON.parse(response[:content].to_s)
      { values: parsed.is_a?(Hash) ? parsed : {}, model: response[:model] }
    # StandardError целиком, а не только OmniClient::Error: клиент перевыбрасывает
    # ошибку последней модели в цепочке как есть, и сетевая (Socket::ResolutionError,
    # таймаут) проходила мимо узкого rescue. Тогда падал весь шаг мастера, а сотрудник
    # не получал вообще ничего — ни разбора, ни отказа. Так и было в песочнице, где
    # адрес моделей заведомо нерабочий.
    rescue StandardError => e
      Rails.logger.warn("[CrmCards::TextIntake] #{e.class}: #{e.message}")
      { values: {}, error: 'Разобрать текст моделью не удалось — заполним по шагам.' }
    end

    def client = @client ||= Llm::OmniClient.new

    def system_prompt
      fields = schema.map do |f|
        options = Array(f.options).map(&:last).join('|')
        "#{f.key} — #{f.label}#{" (#{options})" if options.present?}"
      end
      <<~PROMPT
        Ты разбираешь текст о клиенте агентства недвижимости на поля карточки CRM.
        Верни строго JSON-объект с теми ключами, значения которых ЕСТЬ в тексте:
        #{fields.join("\n")}
        Ничего не придумывай и не достраивай: нет в тексте — нет ключа.
        Телефон — цифрами. Даты не нужны. Комментарий — своими словами, одной фразой.
      PROMPT
    end
  end
end
