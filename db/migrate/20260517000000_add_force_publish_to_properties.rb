# frozen_string_literal: true

# Manual override for the publication gate. When true, Property#ready_for_site?
# returns true regardless of deal_state/in_ad/images/description checks — used
# by admins to keep a listing on the site when CRM state is misaligned (e.g.
# agent forgot to flip `in_ad` in Topnlab).
class AddForcePublishToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :force_publish, :boolean, default: false, null: false
    add_index  :properties, :force_publish, where: 'force_publish = TRUE'
  end
end
