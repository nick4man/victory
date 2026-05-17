# frozen_string_literal: true

# A7 Phase 4 — re-use MagicLinkToken для password-reset flow.
#
# Добавляет `scope` колонку, чтобы один и тот же стол хранил оба типа токенов
# с разными application semantics:
#   - 'login'          — magic-link для входа (default, backwards-compatible)
#   - 'password_reset' — токен установки/смены пароля
#
# Index на (scope, expires_at) — для cleanup-cron'а позже (всё ещё не написан,
# но индекс готов).
class AddScopeToMagicLinkTokens < ActiveRecord::Migration[7.1]
  def change
    add_column :magic_link_tokens, :scope, :string, null: false, default: 'login'
    add_index  :magic_link_tokens, %i[scope expires_at]
  end
end
