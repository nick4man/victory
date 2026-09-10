# frozen_string_literal: true

# Агрегаты по подборке Property одним SQL-запросом. A2 Фаза 3 — введён
# для `ResidentialComplexesController`, который иначе повторил бы паттерн
# `LandingsController` (build_scope пересобирается на count/min/avg отдельно
# по 4 раза за запрос).
#
# Намеренно НЕ адаптирован в LandingsController / PropertiesController /
# Llm::ChatResponder — три существующих потребителя агрегатов имеют разную
# форму запроса и обработку ошибок, а правка трёх горячих прод-путей ради
# нулевого пользовательского эффекта не оправдана. См. план A2, §Вне scope.
# TODO(refactor): adopt ListingStats в трёх местах выше отдельным тикетом.
class ListingStats
  # rubocop:disable Lint/StructNewOverride -- :count member намеренно
  # называется как Struct#count (плановое имя поля, см. план A2 Фаза 3);
  # Result — DTO для чтения атрибутов, а не для Enumerable-обхода.
  Result = Struct.new(
    :count, :min_price, :max_price, :avg_price_per_sqm, :min_area, :max_area,
    keyword_init: true
  )
  # rubocop:enable Lint/StructNewOverride

  # Ловушка: `Arel.sql('COUNT(*), MIN(price), ...')` ОДНОЙ строкой с запятыми
  # вернёт из `pick` только первую колонку — Rails считает столбцы по числу
  # аргументов, а не по содержимому SQL. Поэтому шесть отдельных Arel.sql.
  def self.for(scope)
    # `reorder(nil)` — агрегаты без GROUP BY несовместимы с ORDER BY на
    # колонку вне SELECT (Postgres: "column must appear in the GROUP BY
    # clause or be used in an aggregate function"). Вызывающий код обычно
    # передаёт уже упорядоченный scope (для списка карточек) — здесь этот
    # порядок роли не играет.
    count, min_price, max_price, avg_price_per_sqm, min_area, max_area = scope.reorder(nil).pick(
      Arel.sql('COUNT(*)'),
      Arel.sql('MIN(price)'),
      Arel.sql('MAX(price)'),
      Arel.sql('AVG(price_per_sqm)'),
      Arel.sql('MIN(area)'),
      Arel.sql('MAX(area)')
    )

    Result.new(
      count: count.to_i,
      min_price: min_price,
      max_price: max_price,
      avg_price_per_sqm: avg_price_per_sqm,
      min_area: min_area,
      max_area: max_area
    )
  end
end
