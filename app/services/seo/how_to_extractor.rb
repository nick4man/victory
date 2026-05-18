# frozen_string_literal: true

module Seo
  # Извлекает шаги для Schema.org HowTo из article body HTML.
  # Конвенция: автор пишет шаги как `<ol><li><strong>Заголовок шага</strong>
  # описание текстом...</li></ol>`. <strong> — опциональная метка для
  # HowToStep.name; если её нет, используется "Шаг N".
  #
  # Активируется только когда `extractable?` == true (минимум MIN_STEPS
  # шагов). Иначе partial рендерит nothing — guard от false-positive
  # HowTo Schema на статьях без step-структуры.
  #
  # Я.Wand + Google Rich Results показывают HowTo как accordion в SERP
  # с CTR boost vs. regular Article. Идеально для category=guides.
  class HowToExtractor
    MIN_STEPS = 3
    MAX_STEPS = 12
    TEXT_TRUNCATE = 500

    def initialize(html)
      @html = html.to_s
    end

    def extractable?
      steps.size >= MIN_STEPS
    end

    def steps
      @steps ||= Nokogiri::HTML.fragment(@html).css('ol > li').first(MAX_STEPS).map.with_index(1) do |li, i|
        name = li.css('strong, b').first&.text&.strip&.presence
        full_text = li.text.strip
        body_text = name ? full_text.delete_prefix(name).strip.presence : nil
        {
          '@type' => 'HowToStep',
          'position' => i,
          'name' => name || "Шаг #{i}",
          'text' => (body_text || full_text).truncate(TEXT_TRUNCATE)
        }
      end
    end
  end
end
