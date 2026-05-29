# frozen_string_literal: true

# CaseStudy — анонимизированные кейсы по закрытым сделкам. Активирует
# Pillar 2 стратегического вектора («глубокая экспертиза» через proof of
# past performance). Pipeline: case-study-writer agent драфтит markdown
# body → admin публикует через /admin/case_studies → public видит на
# /cases/:slug.
#
# Naming note: модель CaseStudy (не Case — избегает overlap с Ruby keyword
# `case ... when`). URL остаётся /cases/:slug через resources :case_studies,
# path: 'cases', as: :cases.
class CreateCaseStudies < ActiveRecord::Migration[7.1]
  def change
    create_table :case_studies do |t|
      # === Core content ===
      t.string  :title,         null: false
      t.string  :slug,          null: false
      t.text    :excerpt
      t.text    :body,          null: false
      t.text    :body_html

      # === Anonymized client metadata ===
      # Per anonymization checklist в .claude/agents/case-study-writer.md:
      # alias = «Иван И.», origin = регион не город (кроме МСК/СПб),
      # profession = generic должность (не конкретная компания).
      t.string  :client_alias
      t.string  :client_origin
      t.string  :client_profession

      # === Deal metadata — точные числа stay (это и есть proof) ===
      t.string  :district
      t.integer :property_type,         null: false, default: 0
      t.decimal :area, precision: 8, scale: 2
      t.bigint  :deal_amount
      t.integer :deal_duration_days
      t.string  :bank
      t.string  :mortgage_program

      # === Relations (все optional — кейс может быть исторический без trace) ===
      t.references :author,    foreign_key: { to_table: :users }
      t.references :inquiry,   foreign_key: true
      t.references :property,  foreign_key: true

      # === SEO override (fallback на title/excerpt если nil) ===
      t.string :meta_title
      t.string :meta_description
      t.string :og_image_url

      # === State + counters ===
      t.integer  :status,       null: false, default: 0
      t.datetime :published_at
      t.datetime :deleted_at
      t.integer  :views_count,  null: false, default: 0

      t.timestamps
    end

    add_index :case_studies, :slug, unique: true
    add_index :case_studies, :published_at
    add_index :case_studies, :status
    add_index :case_studies, :deleted_at
    add_index :case_studies, %i[district property_type]
  end
end
