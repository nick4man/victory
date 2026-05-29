# frozen_string_literal: true

class CreateCrmReports < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_reports do |t|
      t.bigint  :crm_id
      t.string  :title, null: false
      t.string  :slug, null: false
      t.integer :page_id, null: false
      t.integer :order_position, default: 1
      t.string  :template_class, null: false
      t.boolean :active, default: true, null: false
      t.datetime :synced_at
      t.timestamps
    end

    add_index :crm_reports, :slug, unique: true
    add_index :crm_reports, :crm_id, unique: true, where: 'crm_id IS NOT NULL'
  end
end
