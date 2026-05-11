# frozen_string_literal: true

# Articles drive the blog and (Phase 2) the weekly market-report cadence.
# title + slug for URL; body holds Markdown source, body_html the rendered
# cache (regenerated in a before_save hook). author_id links to User so the
# byline can pull the agent's photo + bio for E-E-A-T.
class CreateArticles < ActiveRecord::Migration[7.1]
  def change
    create_table :articles do |t|
      t.string  :title,        null: false
      t.string  :slug,         null: false
      t.text    :excerpt
      t.text    :body,         null: false
      t.text    :body_html
      t.references :author, foreign_key: { to_table: :users }
      t.string  :category,     null: false, default: 'guides'
      t.string  :region        # e.g. 'ryazan', nil = federal
      # NewsArticle for news / market reports; BlogPosting for evergreen guides.
      t.string  :schema_type,  null: false, default: 'BlogPosting'
      t.datetime :published_at
      t.integer :views_count,  null: false, default: 0
      t.timestamps
    end

    add_index :articles, :slug, unique: true
    add_index :articles, :published_at
    add_index :articles, %i[category published_at]
    add_index :articles, %i[region published_at]
  end
end
