# frozen_string_literal: true

# #413f Шаг 5 — track source of TgLinkToken для analytics.
# Когда `/start <token>` обработан LinkProcessor — мы знаем какой канал
# создал этот token. Sources mirror'ят activation_events.channel.
class AddSourceToTgLinkTokens < ActiveRecord::Migration[7.1]
  def change
    add_column :tg_link_tokens, :source, :string, limit: 32
    add_index  :tg_link_tokens, :source
  end
end
