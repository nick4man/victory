# frozen_string_literal: true

# Semantic search over indexed Topnlab API docs.
#
# Usage:
#   TopnlabDocs::Searcher.new('как получить список МЛС объектов').call
#   #=> [{ file:, section:, line:, similarity:, text: }, ...]
#
# Used by:
#   - rake topnlab_docs:search['query']
#   - .claude/agents/topnlab-api-expert.md workflow
module TopnlabDocs
  class Searcher
    DEFAULT_LIMIT = 5

    def initialize(query, limit: DEFAULT_LIMIT, client: Embedding::GoogleClient.new)
      @query  = query.to_s.strip
      @limit  = [limit.to_i, 20].min.clamp(1, 20)
      @client = client
    end

    # @return [Array<Hash>]
    def call
      raise ArgumentError, 'query must be non-empty' if @query.empty?

      vec = @client.embed(@query)

      results = TopnlabDocChunk
                .nearest_neighbors(:embedding, vec, distance: 'cosine')
                .limit(@limit)

      results.map do |chunk|
        {
          file:       chunk.source_file,
          section:    chunk.section_title,
          line:       chunk.line_start,
          # neighbor_distance is cosine distance [0..2] → similarity [0..1]
          similarity: (1 - chunk.neighbor_distance / 2.0).round(3),
          text:       chunk.chunk_text
        }
      end
    end
  end
end
