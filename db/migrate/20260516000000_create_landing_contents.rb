# frozen_string_literal: true

# SEO landing content stored in the DB so admins can edit it via the panel
# (and so the chatbot can pull district-specific copy through a tool call).
# Each row is uniquely keyed by (intent, type, district_slug, rooms). The
# LandingsController prefers a DB row over the file-backed ERB partials in
# `app/views/landings/content/` — partials remain as fallback when no row
# exists yet, so the rollout doesn't need a coordinated content migration.
#
# `body_blocks` is a structured array of typed blocks (heading / paragraph
# / quote / link / image / list / faq). The block renderer caches into
# `body_html` (for the page) and `body_plain` (for the chatbot context).
class CreateLandingContents < ActiveRecord::Migration[7.1]
  def change
    create_table :landing_contents do |t|
      t.string  :intent,           null: false                # sale | rent
      t.string  :type,             null: false                # kvartira | dom | uchastok | komnata | kommercheskaya
      t.string  :district_slug                                # nil → type-only landing
      t.string  :rooms                                        # nil | 1..4 | studiya
      t.string  :title,            null: false
      t.string  :meta_description, limit: 300
      t.jsonb   :body_blocks,      default: []
      t.text    :body_html
      t.text    :body_plain
      t.boolean :published,        default: false, null: false

      t.timestamps
    end

    add_index :landing_contents, %i[intent type district_slug rooms],
              unique: true, name: 'idx_landing_contents_uniq'
    add_index :landing_contents, :published
  end
end
