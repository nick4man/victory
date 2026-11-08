# frozen_string_literal: true

module Llm
  # Static page-aware greetings. Used as the auto-seeded first assistant message
  # when a visitor opens the chat. Synchronous, no LLM call — visitors see it
  # instantly. The LLM-driven response kicks in when they actually type something.
  module PageGreeting
    DEFAULT = <<~RU.squish
      Здравствуйте! Я виртуальный консультант АН «Виктори».
      Подскажу по объектам, услугам, ипотеке и оценке. О чём вы хотите узнать?
    RU

    module_function

    # @param page_ctx [Hash{String=>String}, nil] keys: path, query, title, referrer, h1, ctx
    def for(page_ctx)
      return DEFAULT unless page_ctx
      kind = Llm::PageContext.detect(page_ctx['path'], page_ctx['ctx'])
      build(kind, page_ctx)
    end

    def build(kind, ctx)
      case kind
      when :home
        'Добрый день! Помогу подобрать недвижимость, оценить вашу или ответить на любой вопрос об агентстве. С чего начнём?'
      when :catalog
        catalog_greeting
      when :property_show
        property_greeting(ctx)
      when :zhk
        zhk_greeting(ctx)
      when :landing
        'Смотрите подборку объектов. Скажите бюджет или пожелания — уточню поиск по этому направлению.'
      when :valuation_result
        valuation_greeting(ctx)
      when :investment_audit
        audit_greeting(ctx)
      when :investment_audit_new
        'Собираетесь запустить инвест-аудит объекта? Помогу с параметрами или объясню, как читать вердикт и индекс эффективности.'
      when :mortgage
        'Помогу с расчётом ипотеки. Можете ввести параметры выше или просто скажите бюджет и срок — подскажу варианты.'
      when :sell_valuation
        'Хотите оценить или продать недвижимость? Скажите тип объекта и район — подскажу с онлайн-оценкой и подключу агента.'
      when :services
        'Подскажу по нашим услугам — покупка, аренда, ипотека, юридическое сопровождение. Что вас интересует?'
      else
        DEFAULT
      end
    end

    def catalog_greeting
      n = (Property.on_site.count rescue 0)
      base = 'Помочь подобрать объект? Скажите бюджет, район или тип — найду подходящие варианты.'
      n.positive? ? "В каталоге сейчас #{n} объектов в рекламе. #{base}" : base
    end

    def property_greeting(ctx)
      title = ctx['title'].to_s.split(' — ').first.presence # "<Заголовок объекта> — АН Виктори"
      if title
        "Это объект — #{title}. Хотите узнать больше: доступность, торг, юр. чистоту или записаться на просмотр?"
      else
        'Хотите узнать про этот объект больше — доступность, торг, юр. чистоту или записаться на просмотр?'
      end
    end

    def zhk_greeting(ctx)
      # slug — из ctx (если bootstrap/POST его прислал) либо из пути: штатный
      # сценарий открытия чата сразу даёт path, и без fallback'а именное
      # обращение к ЖК не работало бы никогда.
      slug = ctx.dig('ctx', 'slug').to_s.presence || ctx['path'].to_s[%r{\A/zhk/([^/?#]+)}, 1]
      complex = ResidentialComplex.visible.friendly.find(slug) if slug.present?
      name = complex&.display_name
      if name
        "Это жилой комплекс — #{name}. Рассказать про состав объектов, цены или подобрать похожие варианты?"
      else
        'Смотрите жилой комплекс. Рассказать про состав объектов, цены или подобрать похожие варианты?'
      end
    rescue ActiveRecord::RecordNotFound
      'Смотрите жилой комплекс. Рассказать про состав объектов, цены или подобрать похожие варианты?'
    end

    # Страница аудита показывает pending/failed/completed — «аудит готов»
    # корректно только для завершённого расчёта.
    def audit_greeting(ctx)
      case ctx.dig('ctx', 'state').to_s
      when 'pending'
        'Вижу, инвестиционный аудит ещё считается. Помогу пока по другому вопросу — например, объясню, как читать вердикт.'
      when 'failed'
        'Похоже, расчёт аудита не удался. Предложите обновить страницу или попробовать ещё раз чуть позже.'
      else
        'Вижу, инвестиционный аудит объекта готов. Объясню вердикт и стратегию или подскажу следующие шаги.'
      end
    end

    def valuation_greeting(ctx)
      case ctx.dig('ctx', 'state').to_s
      when 'pending'
        'Вижу, оценка ещё считается. Помогу пока по другому вопросу про недвижимость.'
      when 'failed'
        'Похоже, расчёт оценки не удался. Предложите попробовать ещё раз — форма занимает пару минут.'
      else
        'Вижу, ваша оценка готова. Хотите обсудить результат, сравнить с рынком или получить полный отчёт PDF?'
      end
    end
  end
end
