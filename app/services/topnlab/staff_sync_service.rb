# frozen_string_literal: true

# Pulls Topnlab company structure (departments + users) into local Department + User.
# Idempotent: matches User by email (Devise primary key), Department by crm_id.
# Soft-deactivates users who became 'fired' in CRM but never deletes them
# (preserves history of properties/inquiries linked to ex-agents).
module Topnlab
  class StaffSyncService
    STATUS_MAP = { 0 => 'active', 2 => 'fired', 3 => 'invited', 8 => 'blocked' }.freeze

    def initialize(client: Topnlab::Client.new)
      @client = client
    end

    def call
      structure_payload = @client.get_structure
      structure = unwrap_structure(structure_payload)

      dept_count = upsert_structure(structure) if structure

      users_payload = @client.get_users
      user_count = upsert_users(Array(users_payload))

      { success: true, departments: dept_count.to_i, users: user_count.to_i }
    rescue Topnlab::Client::Error => e
      Rails.logger.error("[StaffSync] Topnlab error: #{e.message}")
      { success: false, error: e.message }
    end

    private

    # Topnlab wraps responses inconsistently:
    #   single company  → { status, data: { id, title, users, childs, ... } }
    #                  OR { status, data: { data: { id, ... } } }
    #   group company  → { status, data: [ {...}, {...} ] }
    #                  OR { status, data: { data: [ {...}, {...} ] } }
    # Unwrap up to two levels of "data" until we hit something with id|title|childs.
    def unwrap_structure(payload)
      node = payload.is_a?(Hash) ? payload['data'] : payload
      return node if node.is_a?(Array) && node.first.is_a?(Hash) && node.first['id']
      if node.is_a?(Hash)
        return node if node['id'] || node['childs'] || node['users']
        inner = node['data']
        return inner if inner
      end
      nil
    end

    # Recursively walks the Topnlab structure tree and upserts Department rows.
    # Also tags users in chiefs[] with is_chief=true.
    # @return [Integer] number of departments upserted
    def upsert_structure(node, parent_crm_id: nil)
      return 0 unless node

      # Group-of-companies returns an Array, single company returns a Hash.
      return Array(node).sum { |n| upsert_structure(n, parent_crm_id: nil) } if node.is_a?(Array)

      crm_id = node['id']
      return 0 unless crm_id

      dept = Department.find_or_initialize_by(crm_id: crm_id)
      dept.assign_attributes(
        crm_parent_id: parent_crm_id,
        company_id:    node['company_id'],
        title:         node['title'].presence || "Отдел ##{crm_id}",
        address:       extract_address(node['address']),
        active:        true,
        synced_at:     Time.current
      )
      dept.save!

      mark_chiefs(dept, Array(node['chiefs']))
      assign_dept_to_users(dept, Array(node['users']))

      count = 1
      Array(node['childs']).each do |child|
        count += upsert_structure(child, parent_crm_id: crm_id)
      end
      count
    end

    def extract_address(raw)
      return nil if raw.blank?
      return raw if raw.is_a?(String)
      [raw['city'], raw['street'], raw['house']].compact.join(', ').presence
    end

    def mark_chiefs(department, chiefs)
      chiefs.each do |chief|
        email = chief['email']&.downcase
        next if email.blank?
        user = User.find_by('LOWER(email) = ?', email)
        user&.update_columns(department_id: department.id, is_chief: true)
      end
    end

    def assign_dept_to_users(department, users)
      users.each do |u|
        email = u['email']&.downcase
        next if email.blank?
        user = User.find_by('LOWER(email) = ?', email)
        next unless user
        # Don't override is_chief here; mark_chiefs handles the chief flag.
        user.update_columns(department_id: department.id) if user.department_id != department.id
      end
    end

    # users_payload is a flat array (or hash-of-hashes) of CRM user records.
    # Match by email; create local User on the fly with random password if missing.
    def upsert_users(payload)
      records = normalize_users(payload)
      records.count do |u|
        email = u['email'].to_s.downcase.strip
        next false if email.blank?

        user = User.find_or_initialize_by(email: email)
        first_name  = u['firstname'].presence
        last_name   = u['lastname'].presence
        middle_name = u['fathername'].presence

        # Don't blow away phones/names entered manually in the local DB if Topnlab
        # comes back blank for them — keep what we already have.
        topnlab_phone = normalize_phone(u['phone_num'])
        attrs = {
          first_name:    first_name  || user.first_name.presence || email.split('@').first,
          last_name:     last_name   || user.last_name.presence  || ' ',
          middle_name:   middle_name || user.middle_name,
          phone:         topnlab_phone.presence || user.phone,
          crm_user_id:   u['id'],
          crm_role_id:   u['role'].to_s,
          crm_role_name: u['role_name'],
          crm_status:    STATUS_MAP[u['status'].to_i] || 'active',
          crm_synced_at: Time.current
        }

        if user.new_record?
          attrs[:password] = SecureRandom.hex(16)
          attrs[:role] = :agent
          attrs[:active] = true
          attrs[:confirmed_at] = Time.current
        end

        user.assign_attributes(attrs)
        # Deactivate fired users but keep the record.
        user.active = false if attrs[:crm_status] == 'fired'

        save_user_safely(user, email)
      end
    end

    # Multiple Topnlab users can share a landline → blank phone on UniqueViolation
    # rather than skipping the whole user (we still want their CRM linkage).
    def save_user_safely(user, email)
      user.save(validate: false)
    rescue ActiveRecord::RecordNotUnique => e
      raise e unless e.message.include?('phone')
      user.phone = nil
      user.save(validate: false)
    rescue StandardError => e
      Rails.logger.warn("[StaffSync] save failed for #{email}: #{e.class} #{e.message}")
      false
    end

    def normalize_users(payload)
      case payload
      when Array then payload
      when Hash  then payload.values
      else            []
      end.compact
    end

    def normalize_phone(raw)
      digits = raw.to_s.gsub(/\D/, '')
      return nil if digits.empty?
      digits.start_with?('7', '8') ? "+7#{digits[-10..]}" : "+#{digits}"
    end
  end
end
