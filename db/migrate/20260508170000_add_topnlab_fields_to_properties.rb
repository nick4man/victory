# frozen_string_literal: true

class AddTopnlabFieldsToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :external_source, :string
    add_column :properties, :external_id,     :string
    add_column :properties, :synced_at,       :datetime

    add_index :properties, [:external_source, :external_id], unique: true,
              name: 'index_properties_on_external'
    add_index :properties, :synced_at
  end
end
