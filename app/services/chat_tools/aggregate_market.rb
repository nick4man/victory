# frozen_string_literal: true

module ChatTools
  # Aggregate stats over Property.on_site. Used when the user asks
  # "how many" / "what's the average" / "what's the cheapest" — instead of
  # the bot guessing or calling search_properties for an aggregate.
  module AggregateMarket
    def self.schema
      {
        type: 'function',
        function: {
          name: 'aggregate_market',
          description: 'Агрегированные данные по каталогу (количество, средняя цена, мин/макс) ' \
                       'с фильтрами. Возвращает только числа, не список объектов.',
          parameters: {
            type: 'object',
            properties: {
              deal_type: { type: 'string', enum: %w[sale rent daily] },
              rooms:     { type: 'integer' },
              district:  { type: 'string' },
              group_by:  { type: 'string', enum: %w[district rooms condition], description: 'Группировка для разбивки' }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args)
      args ||= {}
      scope = Property.on_site
      scope = scope.where(deal_type: args[:deal_type])    if args[:deal_type].present?
      scope = scope.where(rooms: args[:rooms])            if args[:rooms].present?
      scope = scope.where('district ILIKE ?', "%#{args[:district]}%") if args[:district].present?

      summary = {
        count:      scope.count,
        avg_price:  scope.average(:price)&.to_i,
        min_price:  scope.minimum(:price)&.to_i,
        max_price:  scope.maximum(:price)&.to_i,
        avg_area:   scope.average(:area)&.to_f&.round(1)
      }

      if args[:group_by].present? && %w[district rooms condition].include?(args[:group_by])
        summary[:breakdown] = scope.group(args[:group_by])
                                   .order(Arel.sql('COUNT(id) DESC'))
                                   .limit(20)
                                   .pluck(args[:group_by], Arel.sql('COUNT(id)'), Arel.sql('AVG(price)::int'), Arel.sql('AVG(area)::numeric(10,1)'))
                                   .map { |k, c, ap, aa| { args[:group_by] => k, count: c, avg_price: ap, avg_area: aa.to_f } }
      end

      summary
    end
  end
end
