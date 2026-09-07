# frozen_string_literal: true

module Admin
  # Поля, по которым источники службы сбора данных о ЖК противоречат друг
  # другу. Экран только показывает: правку вносит редактор в карточке ЖК,
  # потому что решение «кто прав» человеческое, а не автоматическое —
  # разрешение конфликта («принять это значение») сюда намеренно не входит.
  class ZhkDiscrepanciesController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    # Русские подписи для `ZhkFact#field`. Список закрытый и совпадает с
    # `Zhk::FactApplier::FILLABLE` — расхождение по незнакомому полю
    # физически не может попасть на этот экран: `FactApplier` его не
    # применит, а `Discrepancies` строит очередь только из уже
    # применённых кандидатов. Фолбэк на сырое имя — не «на будущее
    # неизвестное поле», а страховка на случай, если этот список и
    # `FILLABLE` разъедутся: молчаливое английское имя терпимо, а падение
    # экрана — нет. Формулировки — как редактор видит их в самой карточке
    # ЖК (`admin/residential_complexes/_form.html.erb`), а не буквальный
    # перевод символа поля.
    FIELD_LABELS = {
      'name' => 'Название',
      'district_slug' => 'Район',
      'developer' => 'Застройщик',
      'address' => 'Адрес',
      'address_patterns' => 'Адресные паттерны',
      'built_from' => 'Год сдачи, от',
      'built_to' => 'Год сдачи, до',
      'buildings_count' => 'Количество корпусов',
      'floors_min' => 'Этажность, от',
      'floors_max' => 'Этажность, до',
      'wall_material' => 'Материал стен',
      'housing_class' => 'Класс жилья',
      'build_status' => 'Статус стройки'
    }.freeze

    # Схемы, которым доверяем в ссылке на источник. `url` приходит от
    # парсера открытых сайтов, то есть от недоверенного источника — без
    # этой проверки `javascript:` в поле долетал бы до `href` рабочей
    # ссылкой (автоэкранирование ERB тут не спасает: `javascript:...` —
    # валидный по синтаксису href, а не разметка).
    ALLOWED_URL_SCHEMES = %w[http https].freeze

    helper_method :field_label, :safe_source_url

    def index
      # `Zhk::Discrepancies.all` уже делает `includes(:residential_complex)`
      # внутри группировки — во вьюхе по `@rows` дополнительных запросов на
      # связь быть не должно.
      @rows = Zhk::Discrepancies.all
    end

    private

    def field_label(field)
      FIELD_LABELS.fetch(field.to_s, field.to_s)
    end

    # @return [String, nil] `url`, если его схема в белом списке, иначе
    # `nil` — вызывающий обязан в этом случае показать значение текстом,
    # а не ссылкой.
    def safe_source_url(url)
      return if url.blank?

      scheme = URI.parse(url).scheme&.downcase
      url if ALLOWED_URL_SCHEMES.include?(scheme)
    rescue URI::InvalidURIError
      nil
    end
  end
end
