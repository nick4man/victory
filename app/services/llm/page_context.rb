# frozen_string_literal: true

module Llm
  # Maps a URL path → page-kind symbol. Used by:
  #   • PageGreeting — to pick the right greeting on conversation open
  #   • ChatResponder — to inject a page-context block into the system prompt
  #
  # Order matters: more specific patterns first.
  module PageContext
    ROUTES = [
      [%r{\A/?\z},                          :landing],
      [%r{\A/properties/map\z},             :catalog],
      [%r{\A/properties\z},                 :catalog],
      [%r{\A/properties/(?<slug>[^/]+)\z},  :property_show],
      [%r{\A/services/mortgage},            :mortgage],
      [%r{\A/sell|\A/valuations},           :sell_valuation],
      [%r{\A/services},                     :services]
    ].freeze

    module_function

    # @param path [String, nil]
    # @return [Symbol] :landing, :catalog, :property_show, :mortgage, :sell_valuation, :services, :other
    def detect(path)
      str = path.to_s
      return :other if str.empty?

      ROUTES.each do |re, kind|
        return kind if str =~ re
      end
      :other
    end

    # Returns a multiline string to prepend to the system prompt — concrete
    # guidance for the LLM about what the visitor is currently looking at.
    # Returns empty string when there's nothing useful to add.
    def block(ctx)
      return '' unless ctx.is_a?(Hash) && ctx['path'].present?

      path = ctx['path']
      kind = detect(path)
      head = "КОНТЕКСТ СТРАНИЦЫ\nПользователь сейчас находится на: #{path}"
      head += " (#{ctx['title']})" if ctx['title'].present?

      tail = case kind
             when :landing
               'Это главная страница. Если запрос абстрактный — сразу предложи помощь по типичным сценариям: подбор объекта, оценка, продажа, ипотека.'
             when :catalog
               'Это каталог объектов. На любой уточнённый запрос обязательно вызывай search_properties с подходящими фильтрами и возвращай 3-5 результатов в виде списка ссылок.'
             when :property_show
               slug = path[%r{\A/properties/([^/?#]+)}, 1]
               if slug
                 "Это страница конкретного объекта (slug: #{slug}). При первом же содержательном вопросе — обязательно вызови `get_property_details(slug: '#{slug}')` чтобы получить полные данные. Любые вопросы пользователя трактуй про этот объект, пока он не скажет иначе. Если вопрос про инвестиционную сторону (стоит ли покупать, окупаемость, EI, ROI, BUY/WAIT) — вызови `run_investment_audit(property_slug: '#{slug}')` и отдай пользователю audit_url ссылкой; не обещай конкретный вердикт до того как он откроет отчёт."
               else
                 'Это страница конкретного объекта. При первом содержательном вопросе вызови get_property_details со slug из URL. При вопросах про инвестпривлекательность — run_investment_audit с тем же slug.'
               end
             when :mortgage
               'Пользователь смотрит ипотечный калькулятор. Помоги с расчётом, объясни ставки, эскалируй на ипотечного агента если нужны нестандартные условия.'
             when :sell_valuation
               'Пользователь думает продать или оценить недвижимость. Начни с уточнения типа объекта и района, предложи онлайн-оценку, при необходимости эскалируй к агенту.'
             when :services
               'Пользователь смотрит услуги агентства. Подскажи по конкретной услуге, при сложных запросах эскалируй.'
             else
               'Прямой контекст страницы неизвестен — отвечай по общему правилу.'
             end

      "#{head}\n#{tail}\n"
    end
  end
end
