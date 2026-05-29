# frozen_string_literal: true

class CreateDepartmentsAndExtendUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :departments do |t|
      t.bigint  :crm_id, null: false
      t.bigint  :crm_parent_id
      t.bigint  :company_id
      t.string  :title, null: false
      t.string  :address
      t.boolean :active, default: true, null: false
      t.datetime :synced_at, null: false
      t.timestamps
    end

    add_index :departments, :crm_id, unique: true
    add_index :departments, :crm_parent_id

    change_table :users, bulk: true do |t|
      t.bigint  :crm_user_id
      t.string  :crm_role_id
      t.string  :crm_role_name
      t.string  :crm_status                 # 'active' | 'fired' | 'invited' | 'blocked'
      t.bigint  :department_id              # logical FK to departments.id (set in app code)
      t.boolean :is_chief, default: false, null: false
      t.string  :middle_name                # отчество для display_name
      t.datetime :crm_synced_at
    end

    add_index :users, :crm_user_id, unique: true, where: 'crm_user_id IS NOT NULL'
    add_index :users, :department_id
  end
end
