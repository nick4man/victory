# frozen_string_literal: true

module ChatTools
  # Structural property filter — the chatbot calls this for any concrete
  # request like "2-комн в Левобережном до 5 млн с балконом".
  #
  # All filters apply on top of Property.in_advertising scope, so the bot
  # only ever sees objects that are currently in advertising.
  module SearchProperties
    MAX_LIMIT = 10

    PROPERTY_TYPE_SLUGS = %w[flat room house land commerce garage].freeze

    def self.schema
      {
        type: 'function',
        function: {
          name: 'search_properties',
          description: 'Поиск объектов недвижимости по структурным фильтрам ' \
                       '(тип объекта, тип сделки, цена, площадь, комнаты, район, метро, удобства). ' \
                       'Используй для конкретных запросов про каталог. ' \
                       'ВАЖНО: для участков/коммерции/гаражей НЕ задавай rooms_min/rooms_max ' \
                       '(у них поле rooms = NULL), фильтруй через property_type.',
          parameters: {
            type: 'object',
            properties: {
              property_type: { type: 'string', enum: PROPERTY_TYPE_SLUGS,
                               description: 'Тип объекта: flat=квартира, room=комната, house=дом, land=участок, commerce=коммерция, garage=гараж' },
              deal_type:     { type: 'string', enum: %w[sale rent daily], description: 'Тип сделки' },
              min_price:     { type: 'integer', description: 'Минимальная цена ₽' },
              max_price:     { type: 'integer', description: 'Максимальная цена ₽' },
              rooms_min:     { type: 'integer', description: 'Минимум комнат (0 = студия). Только для flat/house/room.' },
              rooms_max:     { type: 'integer', description: 'Максимум комнат. Только для flat/house/room.' },
              min_area:      { type: 'number', description: 'Минимум общей площади м² (для участков — м², 1 сотка = 100 м²)' },
              max_area:      { type: 'number', description: 'Максимум общей площади м²' },
              district:      { type: 'string', description: 'Район (свободный текст, ILIKE match)' },
              condition:     { type: 'string', enum: %w[needs_repair normal renovated euro designer] },
              has_balcony:   { type: 'boolean' },
              has_parking:   { type: 'boolean' },
              has_elevator:  { type: 'boolean' },
              near_metro:    { type: 'string', description: 'Название станции метро' },
              order:         { type: 'string', enum: %w[price_asc price_desc area_desc recent], default: 'recent' },
              limit:         { type: 'integer', description: 'Макс. 10', default: 5 }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args)
      args ||= {}
      scope = Property.in_advertising
      if args[:property_type].present? && PROPERTY_TYPE_SLUGS.include?(args[:property_type].to_s)
        scope = scope.joins(:property_type).where(property_types: { slug: args[:property_type] })
      end
      scope = scope.where(deal_type: args[:deal_type])     if args[:deal_type].present?
      scope = scope.where('price >= ?', args[:min_price])  if args[:min_price].present?
      scope = scope.where('price <= ?', args[:max_price])  if args[:max_price].present?
      scope = scope.where('rooms >= ?', args[:rooms_min])  if args[:rooms_min].present?
      scope = scope.where('rooms <= ?', args[:rooms_max])  if args[:rooms_max].present?
      scope = scope.where('area >= ?', args[:min_area])    if args[:min_area].present?
      scope = scope.where('area <= ?', args[:max_area])    if args[:max_area].present?
      scope = scope.where('district ILIKE ?', "%#{args[:district]}%") if args[:district].present?
      scope = scope.where(condition: args[:condition])     if args[:condition].present?
      scope = scope.where(has_balcony:  true)              if args[:has_balcony]
      scope = scope.where(has_parking:  true)              if args[:has_parking]
      scope = scope.where(has_elevator: true)              if args[:has_elevator]
      scope = scope.where('metro_station ILIKE ?', "%#{args[:near_metro]}%") if args[:near_metro].present?

      scope = order(scope, args[:order])

      limit = [(args[:limit] || 5).to_i, MAX_LIMIT].min
      results = scope.limit(limit).map { |p| ChatTools::Format.property(p) }

      {
        count:   results.size,
        results: results,
        total_matching: scope.except(:limit).count
      }
    end

    def self.order(scope, key)
      case key.to_s
      when 'price_asc'  then scope.order(price: :asc)
      when 'price_desc' then scope.order(price: :desc)
      when 'area_desc'  then scope.order(area: :desc)
      else                   scope.order(created_at: :desc)
      end
    end
  end
end
