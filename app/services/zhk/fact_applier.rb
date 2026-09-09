# frozen_string_literal: true

module Zhk
  # Единственная реализация правила «чем можно заполнять карточку ЖК».
  # Ничего не сохраняет — вызывающий сам решает, когда `save!`.
  #
  # Правило зависит от того, сохранена ли запись, и это НЕ то же самое, что
  # `present?`/`blank?` на текущем значении:
  #
  #   * новая запись (`new_record?`) — заполняем любое поле из белого списка,
  #     для которого в `attrs` пришло непустое значение. Человек ещё ничего
  #     не решал, стирать тут нечего.
  #   * сохранённая запись — заполняем ТОЛЬКО поля, где текущее значение
  #     строго `nil`. Пустая строка и пустой массив (у `address_patterns`
  #     дефолт `{}`/`[]` на уровне БД) на сохранённой записи — осознанное
  #     решение редактора стереть значение, а не «поле ещё не заполнено».
  #     Admin::ResidentialComplexesController#normalized_params по той же
  #     причине проверяет `raw.nil?`, а не `blank?` — иначе редактор не
  #     смог бы очистить `address_patterns` через форму: пустая textarea
  #     трактовалась бы как «данных нет» и на следующем прогоне вебхука
  #     стёртое значение восстанавливалось бы обратно.
  module FactApplier
    # Всё, что служба сбора и сид имеют право заполнять. `published`,
    # `body_blocks` и слаг сюда не входят намеренно: это территория редактора.
    FILLABLE = %i[
      name district_slug developer address address_patterns
      built_from built_to buildings_count floors_min floors_max
      wall_material housing_class build_status
    ].freeze

    module_function

    # @return [Boolean] «данных нет»: `nil` (источник промолчал), пустой
    # массив либо строка, в которой нет ничего кроме пробелов.
    #
    # Здесь стоял `value.present?`, и это была заряженная ловушка,
    # описанная прямо в этом файле: `present?` отбрасывает ещё и `false`,
    # так что в день, когда в `FILLABLE` попадут булевы поля удобств
    # (`has_parking`, `has_closed_yard`, `has_playground`,
    # `has_kindergarten`, `has_school`), наблюдение «парковки нет»
    # перестало бы применяться МОЛЧА.
    #
    # `strip` перед `empty?` — не украшение: голый `empty?` (в отличие от
    # `present?`) НЕ считает пустотой «   », и без него строка из одних
    # пробелов доезжала бы в публичную колонку `developer`, а
    # `name: "   "` роняло бы наблюдение целиком в `:invalid`, хотя
    # `name: ""` даёт `:created` — асимметрия ровно там, где её не было.
    # `false` на `strip` не отвечает, так что ловушка остаётся снятой.
    #
    # Предикат общий с `Zhk::Ingest`: пробник обязан валидировать ровно
    # то, что сюда доедет, иначе выходит пара «проверяем одно, применяем
    # другое».
    def empty_value?(value)
      return true if value.nil?
      return value.strip.empty? if value.respond_to?(:strip)

      value.respond_to?(:empty?) && value.empty?
    end

    # @return [Array<Symbol>] поля, которые были заполнены
    def apply(complex, attrs)
      attrs.filter_map do |field, value|
        field = field.to_sym
        next unless FILLABLE.include?(field)
        next if value.nil? # источник промолчал, а не сообщил пустоту

        if complex.new_record?
          # Пустая строка/массив из attrs на новой записи — то же «данных
          # нет», что и nil, заполнять нечем.
          next if empty_value?(value)
        else
          next unless complex.public_send(field).nil?
        end

        complex.public_send(:"#{field}=", value)
        field
      end
    end
  end
end
