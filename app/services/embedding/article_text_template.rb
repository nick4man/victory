# frozen_string_literal: true

module Embedding
  # Builds the structured text for an Article's gemini-embedding-001 vector.
  # Mirrors PropertyTextTemplate — structured frontmatter at the top, then
  # the cleaned body. Truncated to ~8000 chars (≈2000 tokens) which is the
  # model's input cap.
  #
  # The shape matters: putting category/tags/region at the top means
  # cosine-NN naturally clusters "семейная ипотека" with "льготная ипотека",
  # even if body language differs.
  class ArticleTextTemplate
    MAX_CHARS = 8000

    def self.build(article)
      new(article).build
    end

    def initialize(article)
      @article = article
    end

    def build
      return nil if @article.body.blank? && @article.body_html.blank?

      parts = []
      parts << @article.title.to_s.strip
      parts << "Категория: #{@article.category}"
      parts << "Регион: #{@article.region.presence || 'РФ'}"
      tags = Array(@article.metadata&.dig('hashtags'))
      parts << "Теги: #{tags.join(' ')}" if tags.any?
      excerpt = @article.short_excerpt(length: 280) rescue ''
      parts << "Краткое содержание: #{excerpt}" if excerpt.present?
      parts << ''
      parts << plain_body

      parts.join("\n").strip.truncate(MAX_CHARS)
    end

    private

    def plain_body
      raw = @article.body_html.presence || @article.body.to_s
      ActionController::Base.helpers.strip_tags(raw).to_s.gsub(/\s+/, ' ').strip
    end
  end
end
