# frozen_string_literal: true

# total_area is not applicable for `land` (we collect land_area instead).
# Drop the DB-level NOT NULL constraint; presence is enforced conditionally
# by the model based on property_type.
class RelaxPropertyValuationsNotNulls < ActiveRecord::Migration[7.1]
  def change
    change_column_null :property_valuations, :total_area, true
  end
end
