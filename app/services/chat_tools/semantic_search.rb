# frozen_string_literal: true

module ChatTools
  # Vector-based property search via gemini-embedding-001 + pgvector cosine.
  # Use for fuzzy/intent queries the LLM picks up on:
  #   "тихая квартира для семьи с детьми", "недалеко от парка", "под ремонт".
  #
  # Optional `filters` argument layers SearchProperties-style structural
  # constraints on top so we don't return rented objects when user asked sale.
  module SemanticSearch
    MAX_LIMIT = 10

    def self.schema
      {
        type: 'function',
        function: {
          name: 'semantic_search',
          description: 'Семантический поиск объектов по свободному запросу через эмбеддинги. ' \
                       'Используй когда пользователь описывает желаемый объект неструктурно ' \
                       '(\\"для семьи\\", \\"тихая\\", \\"уютная\\", \\"под ремонт\\").',
          parameters: {
            type: 'object',
            required: %w[query],
            properties: {
              query:         { type: 'string', description: 'Свободный текст запроса' },
              limit:         { type: 'integer', default: 5, description: 'Макс. 10' },
              property_type: { type: 'string', enum: %w[flat room house land commerce garage],
                               description: 'Опциональный фильтр типа объекта поверх семантики' },
              deal_type:     { type: 'string', enum: %w[sale rent daily] },
              max_price:     { type: 'integer' },
              district:      { type: 'string' }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args)
      args ||= {}
      query = args[:query].to_s.strip
      return { error: 'empty query' } if query.empty?

      query_vector = Embedding::GoogleClient.new.embed(query)

      base_ids = Property.in_advertising
      if args[:property_type].present?
        base_ids = base_ids.joins(:property_type).where(property_types: { slug: args[:property_type] })
      end
      base_ids = base_ids.where(deal_type: args[:deal_type])     if args[:deal_type].present?
      base_ids = base_ids.where('price <= ?', args[:max_price])  if args[:max_price].present?
      base_ids = base_ids.where('district ILIKE ?', "%#{args[:district]}%") if args[:district].present?

      property_ids = base_ids.pluck(:id)
      return { count: 0, results: [], note: 'no advertising matches' } if property_ids.empty?

      limit = [(args[:limit] || 5).to_i, MAX_LIMIT].min

      neighbors = PropertyEmbedding
                  .where(property_id: property_ids)
                  .nearest_neighbors(:embedding, query_vector, distance: 'cosine')
                  .limit(limit)

      properties_by_id = Property.where(id: neighbors.map(&:property_id)).index_by(&:id)
      results = neighbors.filter_map do |emb|
        p = properties_by_id[emb.property_id]
        next unless p

        # neighbor_distance is in [0..2] for cosine; similarity ≈ 1 - dist/2
        similarity = (1 - (emb.neighbor_distance.to_f / 2)).round(3)
        ChatTools::Format.property(p, similarity: similarity)
      end

      { count: results.size, results: results }
    end
  end
end
