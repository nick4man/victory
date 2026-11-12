# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SpamBlockedEntry do
  it { is_expected.to define_enum_for(:entry_type).with_values(domain: 'domain', url: 'url', ip: 'ip').with_prefix.backed_by_column_of_type(:string) }
  it { is_expected.to define_enum_for(:status).with_values(suspect: 'suspect', blocked: 'blocked').with_prefix.backed_by_column_of_type(:string) }

  it 'soft-delete: default_scope скрывает удалённые, unscoped отдаёт' do
    entry = described_class.create!(entry_type: :domain, value: 'spam-example.com', status: :blocked, source: 'local')
    entry.update!(deleted_at: Time.current)

    expect(described_class.find_by(value: 'spam-example.com')).to be_nil
    expect(described_class.unscoped.find_by(value: 'spam-example.com')).to eq(entry)
  end

  describe '.find_block_for' do
    it 'уровень полного URL приоритетнее доменного' do
      described_class.create!(entry_type: :url, value: 't.me/spam_channel', status: :blocked, source: 'local')
      described_class.create!(entry_type: :domain, value: 't.me', status: :suspect, source: 'local')

      expect(described_class.find_block_for(host: 't.me', path: '/spam_channel')&.value).to eq('t.me/spam_channel')
    end

    it 'доменный blocked ловит любой путь' do
      described_class.create!(entry_type: :domain, value: 'botmasterru.com', status: :blocked, source: 'local')

      expect(described_class.find_block_for(host: 'botmasterru.com', path: '/product52284')).to be_status_blocked
    end

    it 'suspect тоже возвращается (для подсчёта hits)' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example', status: :suspect, source: 'local')

      expect(described_class.find_block_for(host: 'fishy.example', path: '/x')).to eq(entry)
    end

    it 'nil, когда записей нет' do
      expect(described_class.find_block_for(host: 'clean.example', path: nil)).to be_nil
    end
  end

  describe '.record_hit!' do
    it 'инкрементирует hits и ведёт last_hit_at' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example', status: :suspect, source: 'local')

      described_class.record_hit!(entry, key: 'visitor-a')

      expect(entry.reload.hits).to eq(1)
      expect(entry.last_hit_at).to be_present
    end

    it 'кворум: 3 разных ключа за окно → автопереход в blocked' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example', status: :suspect, source: 'local')

      described_class.record_hit!(entry, key: 'v-a')
      described_class.record_hit!(entry, key: 'v-b')
      expect(entry.reload).to be_status_suspect

      described_class.record_hit!(entry, key: 'v-c')
      expect(entry.reload).to be_status_blocked
      expect(entry.blocked_at).to be_present
    end

    it 'повторный hit того же ключа не даёт кворум' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example', status: :suspect, source: 'local')

      5.times { described_class.record_hit!(entry, key: 'same-visitor') }

      expect(entry.reload).to be_status_suspect
      expect(entry.hits).to eq(5)
    end

    it 'старые ключи вне окна 24ч не считаются' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example', status: :suspect, source: 'local')
      stale = [{ 'key' => 'old-1', 'at' => 2.days.ago.iso8601 }, { 'key' => 'old-2', 'at' => 2.days.ago.iso8601 }]
      entry.update_columns(hit_tokens: stale)

      described_class.record_hit!(entry, key: 'new-1')
      expect(entry.reload).to be_status_suspect
    end

    it 'blocked-запись не меняет статус от hits' do
      entry = described_class.create!(entry_type: :domain, value: 'known-spam.example', status: :blocked, source: 'local')

      4.times { |i| described_class.record_hit!(entry, key: "v-#{i}") }

      expect(entry.reload).to be_status_blocked
    end
  end

  describe '.ip_blocked?' do
    it 'точное совпадение по IP' do
      described_class.create!(entry_type: :ip, value: '203.0.113.66', status: :blocked, source: 'ipsum_l3')

      expect(described_class.ip_blocked?('203.0.113.66')).to be(true)
      expect(described_class.ip_blocked?('203.0.113.67')).to be(false)
      expect(described_class.ip_blocked?(nil)).to be(false)
    end
  end
end
