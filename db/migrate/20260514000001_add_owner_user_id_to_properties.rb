# frozen_string_literal: true

# Property already has user_id pointing to the responsible AGENT (Topnlab
# `user.email` → User#id during import). Add a second reference for the
# CLIENT WHO OWNS / IS SELLING the property — populated when a registered
# user submits a sale request via the site. Lets /dashboard/listings show
# «Я продаю через АН» without conflating with agents' workload views.
class AddOwnerUserIdToProperties < ActiveRecord::Migration[7.1]
  def change
    add_reference :properties, :owner_user,
                  foreign_key: { to_table: :users },
                  null: true,
                  index: true
  end
end
