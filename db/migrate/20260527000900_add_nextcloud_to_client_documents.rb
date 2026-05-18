# frozen_string_literal: true

# A6 Phase 2 completion — Nextcloud mirror + Property linkage для ClientDocument.
#
# nextcloud_path — куда положен JSON snapshot (Офис/НЕДВИЖИМОСТЬ/<Type>/<deal>/
# client-intake/<kind>-YYYYMMDD.json). Используется в admin UI для deep-link.
# property_id — для DealFolderResolver (Property → NC deal folder).
class AddNextcloudToClientDocuments < ActiveRecord::Migration[7.1]
  def change
    change_table :client_documents, bulk: true do |t|
      t.string :nextcloud_path
      t.bigint :property_id # FK логический → properties (resolver source)
    end
    add_index :client_documents, :property_id
    add_index :client_documents, :nextcloud_path, where: 'nextcloud_path IS NOT NULL',
                                                  name: 'idx_client_documents_nc_path'
  end
end
