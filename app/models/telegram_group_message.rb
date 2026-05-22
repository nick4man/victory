# frozen_string_literal: true

# Phase 15 — индексированное хранилище group-messages для FTS поиска
# из director DM control panel.
#
# Writing path: `Telegram::InboxSaver#persist_to_db` upsert'ит каждое
# saved message в эту таблицу (soft-fail если БД недоступна).
#
# Reading path: `ChatTools::Staff::SearchGroupMessages` — FTS через
# tsvector. Также direct scopes для daily digest aggregates.
#
# Schema особенности:
#   • body_tsv — generated column (auto-recomputed на body change)
#   • payload_kind: text/photo/voice/document/sticker/system
#   • body может быть пустым для photo без caption — индекс есть, но match
#     не сработает (что OK, search не должен находить «пустые» фото)
class TelegramGroupMessage < ApplicationRecord
  # === Validations ===
  validates :tg_chat_id, :tg_message_id, :sent_at, presence: true
  validates :tg_message_id, uniqueness: { scope: :tg_chat_id }

  # === Scopes ===
  scope :by_sender, ->(tg_user_id_or_username) {
    case tg_user_id_or_username
    when Integer
      where(tg_user_id: tg_user_id_or_username)
    when String
      where('LOWER(sender_username) = ?', tg_user_id_or_username.downcase.sub(/\A@/, ''))
    end
  }
  scope :in_thread, ->(thread_id) { where(tg_thread_id: thread_id) }
  scope :in_period, ->(range) { where(sent_at: range) }
  scope :with_attachment, -> { where(has_attachment: true) }
  scope :text_only, -> { where(payload_kind: 'text') }

  # === Helpers ===

  # Telegram t.me deep-link для click-to-jump к сообщению.
  # Для supergroup с forum-topic нужен thread_id; без него — short URL.
  def tg_link
    return nil if tg_chat_id.blank? || tg_message_id.blank?

    chat = tg_chat_id.to_s.delete_prefix('-100')
    if tg_thread_id.present?
      "https://t.me/c/#{chat}/#{tg_thread_id}/#{tg_message_id}"
    else
      "https://t.me/c/#{chat}/#{tg_message_id}"
    end
  end

  # Sender display label — username с @ если есть, иначе first_name, иначе id.
  def sender_label
    return "@#{sender_username}" if sender_username.present?
    return sender_first_name if sender_first_name.present?

    "tg:#{tg_user_id}"
  end

  # Body excerpt с подсветкой query (для search results UX).
  # @param max_chars [Integer] truncate length
  # @return [String]
  def body_excerpt(max_chars: 200)
    body.to_s.gsub(/\s+/, ' ').strip.truncate(max_chars)
  end

  # === Class-level FTS helper ===

  # Возвращает scope с FTS match + ts_rank_cd сортировкой.
  # plainto_tsquery автосанитизирует ввод (защита от инъекций).
  # @param query [String] free-text user query
  # @return [ActiveRecord::Relation]
  def self.fts(query)
    return none if query.to_s.strip.empty?

    where(
      'body_tsv @@ plainto_tsquery(?, ?)',
      'russian', query
    ).order(
      Arel.sql(
        "ts_rank_cd(body_tsv, plainto_tsquery('russian', #{connection.quote(query)})) DESC"
      )
    )
  end
end
