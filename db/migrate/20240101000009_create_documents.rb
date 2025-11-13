# frozen_string_literal: true

class CreateDocuments < ActiveRecord::Migration[7.0]
  def change
    create_table :documents do |t|
      # Associations
      t.references :property, null: false, foreign_key: true, index: true
      t.references :user, null: true, foreign_key: true, index: true # uploaded by

      # Document info
      t.string :title, null: false
      t.text :description
      t.string :document_type, null: false # 'contract', 'certificate', 'plan', 'report', etc.
      
      # File storage
      t.string :file_url, null: false
      t.string :file_name
      t.string :content_type
      t.bigint :file_size # in bytes
      
      # Metadata
      t.boolean :public, default: false, null: false
      t.integer :downloads_count, default: 0, null: false
      t.datetime :verified_at
      t.references :verified_by, foreign_key: { to_table: :users }, index: true
      
      # Status
      t.string :status, default: 'pending', null: false # pending, approved, rejected
      
      t.timestamps
      t.datetime :deleted_at
    end

    # Indexes
    add_index :documents, :document_type
    add_index :documents, :status
    add_index :documents, :public
    add_index :documents, :deleted_at
    add_index :documents, [:property_id, :document_type]
  end
end

