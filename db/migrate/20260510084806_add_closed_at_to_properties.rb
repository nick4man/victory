# frozen_string_literal: true

class AddClosedAtToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :closed_at, :datetime
    add_index  :properties, %i[deal_state closed_at]
  end
end
