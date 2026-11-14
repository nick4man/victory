# frozen_string_literal: true

# Per-source подтверждения blocked-записи: { source => iso8601 }.
# Запись, которую когда-либо подтверждал blocked-фид, сейчас упавший,
# не протухает и не понижается: сбой источника ≠ исчезновение ключа
# (fail-closed — ревью Kimi, раунд 14). Успешный в прогоне источник
# защиту не даёт — у него был шанс оставить ключ, и он им не воспользовался.
class AddConfirmationsToSpamBlockedEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :spam_blocked_entries, :confirmations, :jsonb, null: false, default: {}
  end
end
