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
      t.string   :entry_type,   null: false                # domain | url | ip
      t.string   :value,        null: false                # нормализованный домен / host+path / ip
      # SHA-256(value): уникальность без B-tree-лимита PG (~2700 байт на ключ)
      # — реальные URL phishing-фидов доходят до ~5 КБ и падали бы
      # PG::ProgramLimitExceeded на каждом синке; value остаётся текстом
      # без индекса (для людей и отладки), все поиски — по digest
      t.string   :value_digest, null: false
      t.string   :status,       null: false, default: 'suspect' # suspect | blocked
      t.string   :source,       null: false                # local | <имя фида>
      t.integer  :hits,         null: false, default: 0    # suspect: счётчик срабатываний
      t.jsonb    :hit_tokens,   null: false, default: []   # последние {ip, vt, at} — кворум по IP
      t.datetime :last_hit_at
      t.datetime :seen_at                                    # последний синк-прогон, где ключ был в фиде (протухание)
      t.datetime :blocked_at                                 # момент перехода suspect → blocked
      t.datetime :deleted_at
      t.timestamps
    end
    # Единственность строки на (entry_type, value_digest) держим ПОЛНЫМ
    # индексом, без исключения soft-deleted: с частичным (deleted_at IS NULL)
    # create_or_find_by! для удалённого ключа молча плодил вторую активную
    # строку (когда-то удалённая + активная = конфликт unique на реанимации
    # flush_batch и падение всего синка), а реанимация через rescue
    # RecordNotUnique возвращала ту же единственную строку
    add_index :spam_blocked_entries, %i[entry_type value_digest],
              unique: true,
              name: 'idx_spam_blocked_entries_type_digest'
    add_index :spam_blocked_entries, :deleted_at
    add_index :spam_blocked_entries, %i[status entry_type]
    # протухание идёт set-based запросом по свежести seen_at внутри источников
    add_index :spam_blocked_entries, %i[source seen_at],
              where: 'deleted_at IS NULL'

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
