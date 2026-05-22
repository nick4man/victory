# frozen_string_literal: true

# 152-ФЗ compliance — explicit «убрать с сайта» request channel. Когда
# агент просит снять публичный профиль, ставим этот timestamp; Topnlab
# staff_sync_service сюда не пишет (см. attrs hash в strafe_sync_service),
# поэтому last-write от Topnlab не reset'нёт.
#
# Реализует:
#   - hide /agents/<slug> → 410 Gone
#   - убрать имя/телефон на /properties/<id> (показывать «АН Виктори»)
#   - убрать из /sitemap-blog.xml (через publicly_listable_agents scope)
#
# Reversible: NULL-ть timestamp обратно — профиль вернётся.
class AddPublicProfileHiddenAtToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :public_profile_hidden_at, :datetime
    add_index :users, :public_profile_hidden_at
  end
end
