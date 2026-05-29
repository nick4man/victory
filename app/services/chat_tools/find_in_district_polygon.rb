# frozen_string_literal: true

module ChatTools
  # Filter properties by ST_Within against a stored district polygon.
  # Falls back to a free-text district ILIKE match if no polygon for that
  # name has been loaded yet — keeps the tool useful before the
  # `rake districts:import_voronezh` task is run.
  module FindInDistrictPolygon
    MAX_LIMIT = 10

    def self.schema
      {
        type: 'function',
        function: {
          name: 'find_in_district_polygon',
          description: 'Поиск объектов в указанном районе по его геополигону (точная гео-граница). ' \
                       'Если полигон района не загружен — fallback на текстовое совпадение поля district.',
          parameters: {
            type: 'object',
            required: %w[district_name],
            properties: {
              district_name: { type: 'string' },
              city:          { type: 'string', description: 'Опционально, для устранения коллизий имён' },
              limit:         { type: 'integer', default: 5, description: 'Макс. 10' }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args)
      args ||= {}
      name  = args[:district_name].to_s
      limit = [(args[:limit] || 5).to_i, MAX_LIMIT].min

      district_scope = District.where('name ILIKE ?', name)
      district_scope = district_scope.where(city: args[:city]) if args[:city].present?
      district = district_scope.first

      if district
        scope = district.properties_within
        results = scope.limit(limit).map { |p| ChatTools::Format.property(p) }
        {
          mode:         'polygon',
          district:     { id: district.id, name: district.name, city: district.city },
          count:        results.size,
          total_matching: scope.except(:limit).count,
          results:      results
        }
      else
        scope = Property.on_site.where('district ILIKE ?', "%#{name}%")
        results = scope.limit(limit).map { |p| ChatTools::Format.property(p) }
        {
          mode:         'fallback_text',
          note:         "Полигон района '#{name}' не загружен — использован text match.",
          count:        results.size,
          total_matching: scope.except(:limit).count,
          results:      results
        }
      end
    end
  end
end
