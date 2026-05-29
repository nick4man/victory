# frozen_string_literal: true

class AddLandAreaToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :land_area_m2, :decimal, precision: 10, scale: 2

    change_column_null :properties, :area, true
  end
end
