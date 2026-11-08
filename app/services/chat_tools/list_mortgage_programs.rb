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

    def self.schema
      {
        type: 'function',
        function: {
          name: 'list_mortgage_programs',
          description: <<~DESC.strip,
            Подбирает актуальные ипотечные программы банков из каталога (семейная, IT, господдержка, Дальний Восток, военная, рыночная). Возвращает до #{MAX_LIMIT} программ: банк, продукт, тип, ставка, мин. первый взнос, срок, требования + сводку counts_by_type и ссылку на /services/mortgage.

            Вызывай когда пользователь спрашивает: «какие ипотечные программы есть», «какая ставка у банков», «что подойдёт семье с детьми», «IT-ипотека», «военная ипотека», «условия банков». НЕ эскалируй на агента — отвечай сам.

            Подбор по ситуации: дети/маткапитал → product_type `family_mortgage`; IT-специалист → `it_mortgage`; военнослужащий → `military_mortgage`; Дальний Восток → `far_east_mortgage`; без льгот — без product_type.

            После подбора, если известны цена объекта и первый взнос — посчитай платёж через calculate_mortgage, передав rate = rate_min выбранной программы. Для вопроса только «сколько платить в месяц» без интереса к программам — сразу calculate_mortgage.
          DESC
          parameters: {
            type: 'object',
            properties: {
              product_type:     { type: 'string', enum: Mortgage::ProgramsService::PRODUCT_TYPES.keys,
                                  description: 'Тип программы. Без параметра — все активные' },
              down_payment_pct: { type: 'number', description: 'Первый взнос в % — вернутся программы, где мин. взнос ≤ указанного' },
              max_rate:         { type: 'number', description: 'Максимально приемлемая ставка % годовых — программы с rate_min ≤ max_rate' },
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
      programs = programs.select { |p| p[:product_type].to_s == type } if type.present?

      if args[:down_payment_pct].to_f.positive?
        dp = args[:down_payment_pct].to_f
        programs = programs.select { |p| p[:down_payment_min_pct].nil? || p[:down_payment_min_pct] <= dp }
      end

      if args[:max_rate].to_f.positive?
        max = args[:max_rate].to_f
        programs = programs.select { |p| p[:rate_min].nil? || p[:rate_min] <= max }
      end

      programs.sort_by { |p| p[:rate_min] || Float::INFINITY }
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
        rate:                 p[:rate_min],
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

    def self.requirements_display(requirements)
      text = requirements.is_a?(Array) ? requirements.join('; ') : requirements.to_s
      text.truncate(200)
    end

    def self.page_url(args)
      params = {}
      params[:product_type] = args[:product_type] if args[:product_type].present?
      params[:down_payment_pct] = args[:down_payment_pct] if args[:down_payment_pct].to_f.positive?
      params[:rate] = args[:max_rate] if args[:max_rate].to_f.positive?
      query = params.to_query
      query.empty? ? PAGE_PATH : "#{PAGE_PATH}?#{query}"
    end
  end
end
