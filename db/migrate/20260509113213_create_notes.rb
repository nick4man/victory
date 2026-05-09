# frozen_string_literal: true

class CreateNotes < ActiveRecord::Migration[7.1]
  def change
    create_table :notes do |t|
      t.references :notable, polymorphic: true, null: false, index: true
      t.bigint  :crm_note_id
      t.bigint  :crm_user_id
      t.references :user, foreign_key: true
      t.text    :note, null: false
      t.string  :sync_state, default: 'pending', null: false
      t.datetime :synced_at
      t.string  :crm_entity_type
      t.timestamps
    end

    add_index :notes, :crm_note_id, unique: true, where: 'crm_note_id IS NOT NULL'
    add_index :notes, :sync_state
  end
end
