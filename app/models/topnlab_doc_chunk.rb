# frozen_string_literal: true

# == Schema Information
#
# Table name: topnlab_doc_chunks
#
#  id            :bigint       not null, primary key
#  source_file   :string       not null  # e.g. 'listings-and-mls.md'
#  chunk_index   :integer      not null  # 0-based position within the file
#  section_title :string                  # e.g. '## 4. Получать объекты МЛС из Topnlab'
#  line_start    :integer                 # line number in source markdown
#  chunk_text    :text         not null
#  content_hash  :string       not null  # SHA256(chunk_text)
#  embedding     :vector(768)  not null
#  embedded_at   :datetime     not null
#  created_at    :datetime     not null
#  updated_at    :datetime     not null
#
# Internal-only docs — not exposed to site visitors or the site chatbot.
# Used by the `topnlab-api-expert` Claude Code subagent via
# `rake topnlab_docs:search[query]`.
#
# See `.claude/docs/topnlab/` for the source markdown.
class TopnlabDocChunk < ApplicationRecord
  has_neighbors :embedding

  validates :source_file,   presence: true
  validates :chunk_index,   presence: true, numericality: { only_integer: true }
  validates :chunk_text,    presence: true
  validates :content_hash,  presence: true
  validates :chunk_index,   uniqueness: { scope: :source_file }

  scope :by_file,    ->(file)    { where(source_file: file) }
  scope :by_section, ->(section) { where('section_title ILIKE ?', "%#{section}%") }
end
