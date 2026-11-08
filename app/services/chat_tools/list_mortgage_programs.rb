# frozen_string_literal: true

module ChatTools
  # Подбор актуальных ипотечных программ банков из Mortgage::ProgramsService
  # (каталог audit-engine, кэш 6ч). Дополняет calculate_mortgage: тот отвечает
  # «сколько платить», этот — «какие программы есть и что подойдёт под мою
  # ситуацию». Бот сначала подбирает программу (дети → family_mortgage,
  # IT → it_mortgage, военный → military_mortgage, ДФО → far_east_mortgage),
  # затем при наличии цены и взноса досчитывает платёж через calculate_mortgage
  # по ставке выбранной программы. Эскалация к агенту по этим вопросам —
  # регрессия, см. issue #168.
  module ListMortgagePrograms
    DEFAULT_LIMIT = 5
    MAX_LIMIT     = 10
    PAGE_PATH     = '/services/mortgage'

    # Канонические ипотечные типы engine (BankProductType). PRODUCT_TYPES шире:
    # включает consumer_loan/deposit и legacy-алиасы — в выдачу чат-инструмента
    # неипотечные продукты не должны попадать (ревью PR #181).
    MORTGAGE_TYPES = %w[
      mortgage
      family_mortgage
      it_mortgage
      subsidized
      refinance
      far_east_mortgage
      military_mortgage
    ].freeze

    def self.schema
      {
        type: 'function',
        function: {
          name: 'list_mortgage_programs',
          description: <<~DESC.strip,
            Подбирает актуальные ипотечные программы банков из каталога (семейная, IT, господдержка, Дальний Восток, военная, рыночная, рефинансирование). Возвращает до #{MAX_LIMIT} программ: банк, продукт, тип, ставка от (rate_min), мин. первый взнос, срок, требования + сводку counts_by_type и ссылку на страницу калькулятора #{PAGE_PATH}.

            Вызывай когда пользователь спрашивает: «какие ипотечные программы есть», «какая ставка у банков», «что подойдёт семье с детьми», «IT-ипотека», «военная ипотека», «условия банков». НЕ эскалируй на агента — отвечай сам.

            Подбор по ситуации: дети/маткапитал → product_type `family_mortgage`; IT-специалист → `it_mortgage`; военнослужащий → `military_mortgage`; Дальний Восток → `far_east_mortgage`; без льгот — без параметра.

            После подбора, если известны цена объекта и первый взнос — посчитай платёж через calculate_mortgage, передав rate = rate_min выбранной программы. Для вопроса только «сколько платить в месяц» без интереса к программам — сразу calculate_mortgage.

            Если каталог вернул error `programs_unavailable` — честно сообщи, что программы банков сейчас недоступны, извинись и предложи помощь агента. Это единственный случай эскалации по ипотечным вопросам.
          DESC
          parameters: {
            type: 'object',
            properties: {
              product_type:     { type: 'string', enum: MORTGAGE_TYPES,
                                  description: 'Тип программы. Без параметра — все активные ипотечные' },
              down_payment_pct: { type: 'number', description: 'Первый взнос в % — вернутся программы, где мин. взнос ≤ указанного' },
              max_rate:         { type: 'number', description: 'Максимально приемлемая ставка % годовых — программы со ставкой от (rate_min) ≤ max_rate' },
              limit:            { type: 'integer', description: "Сколько программ вернуть (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT})" }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args = {})
      programs = Mortgage::ProgramsService.all
      if programs.empty?
        return { status: 'error', error: 'programs_unavailable',
                 message: 'Каталог ипотечных программ сейчас недоступен' }
      end

      filtered = filter(programs.reject { |p| p[:active] == false }, args)

      {
        status:           'ok',
        programs:         filtered.first(limit(args)).map { |p| present(p) },
        counts_by_type:   counts_by_type(filtered),
        total_matching:   filtered.size,
        page_url:         page_url(args)
      }
    end

    def self.filter(programs, args)
      type = args[:product_type].to_s
      programs = programs.select { |p| MORTGAGE_TYPES.include?(p[:product_type].to_s) }
      programs = programs.select { |p| type_match?(p, type) } if type.present?

      # nil в каталоге — «условие неизвестно», не «подходит под любой порог»:
      # при заданном фильтре такие записи исключаем, а 0 — валидное значение.
      unless args[:down_payment_pct].nil?
        dp = args[:down_payment_pct].to_f
        programs = programs.reject { |p| p[:down_payment_min_pct].nil? || p[:down_payment_min_pct] > dp }
      end

      unless args[:max_rate].nil?
        max = args[:max_rate].to_f
        programs = programs.reject { |p| p[:rate_min].nil? || p[:rate_min] > max }
      end

      programs.sort_by { |p| p[:rate_min] || Float::INFINITY }
    end

    # Каталог хранит Дальневосточную ипотеку как subsidized с
    # requirements.region = far_east (seed audit-engine), а не отдельным типом —
    # иначе штатный фильтр far_east_mortgage её не находит.
    def self.type_match?(program, type)
      return true if program[:product_type].to_s == type
      return false unless type == 'far_east_mortgage'

      program[:product_type].to_s == 'subsidized' && region_of(program) == 'far_east'
    end

    def self.region_of(program)
      req = program[:requirements]
      req.is_a?(Hash) ? (req['region'] || req[:region]).to_s : ''
    end

    def self.limit(args)
      (args[:limit].presence || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
    end

    def self.counts_by_type(programs)
      programs.group_by { |p| p[:product_type_ru] || p[:product_type].to_s }
              .transform_values(&:size)
    end

    def self.present(p)
      {
        bank:                 p[:bank_name],
        product:              p[:product_name],
        type_ru:              p[:product_type_ru],
        rate_min:             p[:rate_min],
        down_payment_min_pct: p[:down_payment_min_pct],
        term:                 term_display(p),
        requirements:         requirements_display(p[:requirements])
      }
    end

    def self.term_display(p)
      min = p[:term_years_min].to_i
      max = p[:term_years_max].to_i
      return '' if min.zero? && max.zero?
      return "от #{min} лет" if max.zero?
      return "до #{max} лет" if min.zero?
      return "#{min} лет" if min == max

      "#{min}–#{max} лет"
    end

    # Engine отдаёт requirements как dict[str, Any] (models.py BankOffer),
    # normalize его не меняет — Hash обрабатываем отдельно с локализацией
    # известных ключей; неизвестные (служебные метаданные scraper'ов: sravni_id,
    # program_codes и т.п.) не показываем — filter_map их отбрасывает.
    def self.requirements_display(requirements)
      text =
        case requirements
        when Hash
          requirements.filter_map { |k, v| requirement_label(k, v) }.join('; ')
        when Array
          requirements.join('; ')
        else
          requirements.to_s
        end
      text.truncate(200)
    end

    def self.requirement_label(key, value)
      case key.to_s
      when 'has_children_under_18' then 'Дети до 18 лет'
      when 'is_it_specialist'      then 'Работа в IT'
      when 'income_min'            then "Доход от #{ActiveSupport::NumberHelper.number_to_delimited(value.to_i)} ₽/мес"
      when 'age_max'               then "Возраст до #{value} лет"
      when 'region'                then "Регион: #{REGIONS[value.to_s] || value}"
      when 'location'              then "Локация: #{LOCATIONS[value.to_s] || value}"
      end
    end

    REGIONS    = { 'far_east' => 'Дальний Восток' }.freeze
    LOCATIONS  = { 'rural' => 'сельская местность' }.freeze
    private_constant :REGIONS, :LOCATIONS

    # Только параметры, которые реально применяет MortgageCalculatorsController
    # (build_form_state читает down_payment_pct; product_type/rate — нет,
    # ссылку с ними нельзя выдавать как «отфильтрованную», ревью PR #181).
    def self.page_url(args)
      return PAGE_PATH if args[:down_payment_pct].nil?

      "#{PAGE_PATH}?#{{ down_payment_pct: args[:down_payment_pct] }.to_query}"
    end
  end
end
