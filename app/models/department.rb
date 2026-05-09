# frozen_string_literal: true

# Mirrors Topnlab CRM company structure (отделы) synced via Topnlab::StaffSyncService.
# Tree relations follow `crm_parent_id` (Topnlab IDs), not local PKs, so cross-references
# survive local PK reshuffles.
class Department < ApplicationRecord
  belongs_to :parent,
             class_name: 'Department',
             foreign_key: :crm_parent_id,
             primary_key: :crm_id,
             optional: true

  has_many :children,
           class_name: 'Department',
           foreign_key: :crm_parent_id,
           primary_key: :crm_id,
           dependent: :nullify

  has_many :users, dependent: :nullify

  scope :roots,  -> { where(crm_parent_id: nil) }
  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:title) }

  def chiefs
    users.where(is_chief: true)
  end

  def all_descendants
    Department.where(crm_parent_id: collect_descendant_ids)
  end

  private

  def collect_descendant_ids
    ids = [crm_id]
    queue = [self]
    until queue.empty?
      current = queue.shift
      kids = Department.where(crm_parent_id: current.crm_id).to_a
      ids.concat(kids.map(&:crm_id))
      queue.concat(kids)
    end
    ids
  end
end
