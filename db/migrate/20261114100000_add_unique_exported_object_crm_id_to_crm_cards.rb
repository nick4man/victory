# frozen_string_literal: true

class AddUniqueExportedObjectCrmIdToCrmCards < ActiveRecord::Migration[8.1]
  def change
    add_index :crm_cards, :crm_id, unique: true,
              where: "kind = 'object' AND status = 'exported' AND crm_id IS NOT NULL",
              name: 'idx_crm_cards_unique_exported_object_crm_id'
  end
end
