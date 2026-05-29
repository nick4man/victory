# frozen_string_literal: true

# 152-ФЗ — реестр phone-numbers с которыми мы НЕ можем инициировать
# контакт (email/SMS/звонок/TG). Создаётся при:
#   1. Жалобе клиента на спам ("у вас рассылка достала")
#   2. Отзыве согласия на обработку ПД (Article 9 152-ФЗ)
#   3. Manual ввода админом для known bad numbers
#
# Use site:
#   CabinetInvitationDispatcher.call(user, ...) — pre-flight check
#     skip all channels если PhoneStopList.blocked?(user.phone)
#   Inquiry create flow — соответствующий validator (отдельный commit)
#   Future: Topnlab webhook on inbound call — refuse to log если blocked
#
# Idempotency: phone stored as last-10-digits (canonical form). Поиск
# через `.blocked?(phone)` который сам нормализует input.
class CreatePhoneStopLists < ActiveRecord::Migration[7.1]
  def change
    create_table :phone_stop_lists do |t|
      # phone хранится как last-10 цифр (canonical) — `9009694844`.
      # Это совпадает с MagicLinkToken normalize ('phone' type).
      t.string :phone_last10, null: false, limit: 10

      # Free-text reason: complaint text, дата отказа, ссылка на письмо.
      # DLP: НЕ должно содержать персональные данные кроме самого факта
      # запроса на исключение.
      t.string :reason, null: false, limit: 500

      # Кто добавил — admin user через future UI, OR self-service
      # (отозвал согласие в кабинете), OR :system (auto-discovered).
      t.string :added_by, null: false, limit: 60  # 'admin', 'self', 'system'
      t.references :added_by_user, foreign_key: { to_table: :users }, null: true

      # Опц.: source текст жалобы / снимок звонка — для compliance audit.
      t.text :source_note

      # Истечение срока (152-ФЗ §9 — отозвавший имеет право на permanent
      # exclusion). По умолчанию nil = бессрочно.
      t.datetime :expires_at

      # Soft-delete consistent (если случайно добавили — отменить, не
      # потерять audit-trail).
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :phone_stop_lists, :phone_last10, unique: true,
              where: 'deleted_at IS NULL'
    add_index :phone_stop_lists, :expires_at
  end
end
