# frozen_string_literal: true

# Phase 3b — track partner agency portal logins.
# Used for: «давно не заходили» reminders, churn analysis.
class AddLastLoginAtToPartnerAgencies < ActiveRecord::Migration[7.1]
  def change
    add_column :partner_agencies, :last_login_at, :datetime
  end
end
