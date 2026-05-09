# frozen_string_literal: true

# Direct-link target for services that have a dedicated dedicated landing page
# (e.g. /valuations/new, /services/mortgage_calculator). When set, the public
# /services card links there instead of opening the generic feedback modal.
class AddTargetPathToServiceTypes < ActiveRecord::Migration[7.1]
  def change
    add_column :service_types, :target_path, :string
  end
end
