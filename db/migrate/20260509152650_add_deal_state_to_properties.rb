# frozen_string_literal: true

# Adds CRM `deal_state` (lead/active/ad/prepayment/denied/deal/deferred/archive)
# to Property. Internal Property#status (draft/active/...) stays separate —
# deal_state mirrors CRM workflow stage, status mirrors website moderation.
class AddDealStateToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :deal_state, :string
    add_index  :properties, :deal_state
  end
end
