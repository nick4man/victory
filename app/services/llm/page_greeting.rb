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

    # @param page_ctx [Hash{String=>String}, nil] keys: path, query, title, referrer
    def for(page_ctx)
      return DEFAULT unless page_ctx
      kind = Llm::PageContext.detect(page_ctx['path'])
      build(kind, page_ctx)
    end

    def build(kind, ctx)
      case kind
      when :landing
        'Добрый день! Помогу подобрать недвижимость, оценить вашу или ответить на любой вопрос об агентстве. С чего начнём?'
      when :catalog
        catalog_greeting
      when :property_show
        property_greeting(ctx)
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
      n = (Property.in_advertising.count rescue 0)
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
  end
end
