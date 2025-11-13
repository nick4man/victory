# frozen_string_literal: true

class CreatePropertyTypes < ActiveRecord::Migration[7.1]
  def change
    create_table :property_types do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.string :icon
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      
      # Stats
      t.integer :properties_count, default: 0, null: false
      
      t.timestamps
    end
    
    add_index :property_types, :slug, unique: true
    add_index :property_types, :position
    add_index :property_types, :active
  end
end