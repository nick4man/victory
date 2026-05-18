# frozen_string_literal: true

# D3 — Client invitation tracking. Records когда CabinetInvitationMailer
# впервые отправил «вам привязан объект» email. Используется чтобы:
#   1. Не повторять invitation если client уже invited
#   2. Admin UI показывал «invitation sent X дней назад / never»
#   3. Retroactive opt-out — existing 14 from-CRM agents + 4 manual
#      clients остаются с invited_at=NULL (не получат retroactive
#      invitation — это intentional, мы не спамим).
#
# NULL default — existing users unchanged.
class AddInvitedAtToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :invited_at, :datetime, null: true
    add_index  :users, :invited_at, where: 'invited_at IS NOT NULL'
  end
end
