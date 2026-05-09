# frozen_string_literal: true

class AddLandFieldsToPropertyValuations < ActiveRecord::Migration[7.1]
  def change
    change_table :property_valuations, bulk: true do |t|
      t.decimal :land_area,      precision: 10, scale: 2  # in сотки (1 сотка = 100 м²)
      t.string  :land_category                              # ИЖС / ЛПХ / СНТ / etc.
      t.string  :ownership_type                             # собственность / аренда
    end
  end
end
