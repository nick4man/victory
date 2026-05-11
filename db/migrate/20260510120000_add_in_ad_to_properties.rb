# frozen_string_literal: true

class AddInAdToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :in_ad, :boolean, default: false, null: false
    add_index  :properties, :in_ad
  end
end
