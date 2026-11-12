# frozen_string_literal: true

# Антиспам-блок-лист чат-бота (issue #219). Три вида записей:
# домен (блок любого URL на нём), полный host+path (блок одной страницы
# белого домена — t.me/spam_channel) и IP (репутационные фиды).
#
# Пополнение двумя путями: cron-синк публичных фидов (source = hagezi_tif,
# phishing_domains, ipsum_l3, …; status = blocked) и локальные эвристики
# бота (source = local; status = suspect → автоблок по кворуму hits).
class CreateSpamBlocklist < ActiveRecord::Migration[8.1]
  def change
    create_table :spam_blocked_entries do |t|
      t.string   :entry_type, null: false                    # domain | url | ip
      t.string   :value,      null: false                    # нормализованный домен / host+path / ip
      t.string   :status,     null: false, default: 'suspect' # suspect | blocked
      t.string   :source,     null: false                    # local | <имя фида>
      t.integer  :hits,       null: false, default: 0        # suspect: счётчик срабатываний
      t.jsonb    :hit_tokens, null: false, default: []       # последние {ip, vt, at} — кворум по IP
      t.datetime :last_hit_at
      t.datetime :blocked_at                                 # момент перехода suspect → blocked
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :spam_blocked_entries, %i[entry_type value],
              unique: true, where: 'deleted_at IS NULL',
              name: 'idx_spam_blocked_entries_type_value'
    add_index :spam_blocked_entries, :deleted_at
    add_index :spam_blocked_entries, %i[status entry_type]

    # Популярные белые домены (Tranco Top-10k, синкается cron'ом): эвристикам
    # нельзя автоблочить корень t.me/youtube.com — только конкретный путь.
    # manual = добавлен вручную/кодом (наш домен): синк не стирает такие.
    create_table :spam_allowlist_entries do |t|
      t.string   :domain, null: false
      t.boolean  :manual, null: false, default: false
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :spam_allowlist_entries, :domain,
              unique: true, where: 'deleted_at IS NULL',
              name: 'idx_spam_allowlist_entries_domain'
    add_index :spam_allowlist_entries, :deleted_at
  end
end
