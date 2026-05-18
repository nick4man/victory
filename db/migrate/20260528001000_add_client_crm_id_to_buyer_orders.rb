# frozen_string_literal: true

# P1b: store the Topnlab client.id on BuyerOrder so we can eventually
# cross-reference a BuyerOrder to a User row (when that client has a local
# account).  Also adds an index to support future look-ups like
#   BuyerOrder.where(client_crm_id: user.crm_user_id).
class AddClientCrmIdToBuyerOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :buyer_orders, :client_crm_id, :bigint
    add_index  :buyer_orders, :client_crm_id
  end
end
