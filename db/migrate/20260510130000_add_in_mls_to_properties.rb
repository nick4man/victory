# frozen_string_literal: true

class AddInMlsToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :in_mls, :boolean, default: false, null: false
    add_index  :properties, :in_mls
  end
end
