# frozen_string_literal: true

# Indexes .claude/docs/topnlab/*.md into TopnlabDocChunk rows with
# gemini-embedding-001 vectors. Splits by H2 (`## `) headers; if a section
# exceeds MAX_CHUNK_CHARS, splits further on blank lines so no single chunk
# exceeds the embedding model's effective context window.
#
# SHA256 content_hash guards re-embed work: unchanged chunks are kept.
# Stale chunks (sections removed in source) are deleted.
#
# Rate-limited at ~85 RPM to fit Gemini's free tier (100 RPM ceiling).
module TopnlabDocs
  class Indexer
    DOCS_DIR        = Rails.root.join('.claude/docs/topnlab').freeze
    INDEXED_FILES   = %w[
      listings-and-mls.md
      call-center.md
      reports.md
      clients-fields.md
      migration-roadmap.md
      README.md
    ].freeze
    MAX_CHUNK_CHARS = 4000
    SLEEP_SECS      = 0.7  # ~85 RPM

    def initialize(client: Embedding::GoogleClient.new)
      @client = client
    end

    # Re-index every file. Returns counts per file.
    def call
      stats = {}
      INDEXED_FILES.each do |filename|
        path = DOCS_DIR.join(filename)
        unless path.exist?
          Rails.logger.warn("[TopnlabDocs::Indexer] #{filename} not found — skipping")
          next
        end
        stats[filename] = index_file(path)
      end
      stats
    end

    # @return [Hash] { inserted:, updated:, unchanged:, removed: }
    def index_file(path)
      filename = path.basename.to_s
      chunks = split_into_chunks(path.read, filename)

      stats = { inserted: 0, updated: 0, unchanged: 0, removed: 0 }

      chunks.each_with_index do |chunk, idx|
        result = upsert_chunk(filename: filename, chunk_index: idx, **chunk)
        stats[result] += 1
      end

      # Remove leftover chunks if source shrank.
      removed = TopnlabDocChunk
                .by_file(filename)
                .where('chunk_index >= ?', chunks.size)
                .delete_all
      stats[:removed] = removed

      Rails.logger.info("[TopnlabDocs::Indexer] #{filename}: #{stats.inspect}")
      stats
    end

    private

    # Splits markdown into chunks.
    #   1. Each top-level (## ) section is its own chunk.
    #   2. Headerless preamble is its own chunk.
    #   3. If a section exceeds MAX_CHUNK_CHARS, split on blank lines.
    #
    # @return [Array<Hash>] [{ section_title:, line_start:, text: }, ...]
    def split_into_chunks(text, filename)
      lines = text.lines
      sections = []
      buf = []
      buf_title = nil
      buf_line_start = 1

      lines.each_with_index do |line, i|
        if line.start_with?('## ')
          # Flush previous section
          flush_section(sections, buf, buf_title, buf_line_start, filename)
          buf = [line]
          buf_title = line.chomp.strip
          buf_line_start = i + 1
        else
          buf << line
        end
      end
      flush_section(sections, buf, buf_title, buf_line_start, filename)

      sections
    end

    def flush_section(sections, buf, title, line_start, filename)
      return if buf.empty?

      text = buf.join
      return if text.strip.empty?

      label = title || "#{filename} (preamble)"

      if text.length <= MAX_CHUNK_CHARS
        sections << { section_title: label, line_start: line_start, text: text }
      else
        split_long_section(text, label, line_start).each { |c| sections << c }
      end
    end

    # Long section → split on blank lines, packing into ≤ MAX_CHUNK_CHARS each.
    def split_long_section(text, title, line_start)
      parts = text.split(/\n{2,}/)
      out = []
      pack = +''
      pack_start = line_start
      offset = 0

      parts.each do |part|
        candidate = pack.empty? ? part : "#{pack}\n\n#{part}"
        if candidate.length > MAX_CHUNK_CHARS && pack.length.positive?
          out << { section_title: title, line_start: pack_start, text: pack }
          pack = part
          pack_start = line_start + offset
        else
          pack = candidate
        end
        offset += part.lines.size + 1
      end
      out << { section_title: title, line_start: pack_start, text: pack } if pack.present?
      out
    end

    def upsert_chunk(filename:, chunk_index:, section_title:, line_start:, text:)
      hash = Digest::SHA256.hexdigest(text)
      existing = TopnlabDocChunk.find_by(source_file: filename, chunk_index: chunk_index)

      if existing && existing.content_hash == hash
        return :unchanged
      end

      vec = @client.embed(text)
      sleep(SLEEP_SECS) # rate-limit Gemini free tier

      if existing
        existing.update!(
          section_title: section_title,
          line_start:    line_start,
          chunk_text:    text,
          content_hash:  hash,
          embedding:     vec,
          embedded_at:   Time.current
        )
        :updated
      else
        TopnlabDocChunk.create!(
          source_file:   filename,
          chunk_index:   chunk_index,
          section_title: section_title,
          line_start:    line_start,
          chunk_text:    text,
          content_hash:  hash,
          embedding:     vec,
          embedded_at:   Time.current
        )
        :inserted
      end
    end
  end
end
