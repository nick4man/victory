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

    it 'suspect-URL не маскирует blocked-домен' do
      described_class.create!(entry_type: :url, value: 'evil.example/page', status: :suspect, source: 'local')
      described_class.create!(entry_type: :domain, value: 'evil.example', status: :blocked, source: 'local')

      expect(described_class.find_block_for(host: 'evil.example', path: '/page')).to be_status_blocked
    end

    it 'allowlist снимает только доменный блок (рекомендованный в runbook разблок)' do
      described_class.create!(entry_type: :domain, value: 'popular.example', status: :blocked, source: 'phishing_domains')
      SpamAllowlistEntry.create!(domain: 'popular.example')

      expect(described_class.find_block_for(host: 'popular.example', path: nil)).to be_nil
    end

    it 'blocked URL на allowlist-домене бьёт — путь точнее белого корня' do
      SpamAllowlistEntry.create!(domain: 'popular.example')
      described_class.create!(entry_type: :url, value: 'popular.example/bad', status: :blocked, source: 'phishing_links')

      expect(described_class.find_block_for(host: 'popular.example', path: '/bad')).to be_status_blocked
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

      described_class.record_hit!(entry, ip: '198.51.100.10', visitor_token: 'visitor-a')

      expect(entry.reload.hits).to eq(1)
      expect(entry.last_hit_at).to be_present
    end

    it 'кворум: 3 разных IP за окно → автопереход в blocked' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example', status: :suspect, source: 'local')

      described_class.record_hit!(entry, ip: '198.51.100.10', visitor_token: 'v-a')
      described_class.record_hit!(entry, ip: '198.51.100.11', visitor_token: 'v-b')
      expect(entry.reload).to be_status_suspect

      described_class.record_hit!(entry, ip: '198.51.100.12', visitor_token: 'v-c')
      expect(entry.reload).to be_status_blocked
      expect(entry.blocked_at).to be_present
    end

    it 'один IP с разными visitor_token не даёт кворум (cookie сбрасывается одним кликом)' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example', status: :suspect, source: 'local')

      described_class.record_hit!(entry, ip: '198.51.100.10', visitor_token: 'v-a')
      described_class.record_hit!(entry, ip: '198.51.100.10', visitor_token: 'v-b')
      described_class.record_hit!(entry, ip: '198.51.100.10', visitor_token: 'v-c')

      expect(entry.reload).to be_status_suspect
      expect(entry.hit_tokens.map { |t| t['ip'] }.uniq.size).to eq(1)
    end

    it 'повторный hit с тем же IP+token не раздувает кворум' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example', status: :suspect, source: 'local')

      5.times { described_class.record_hit!(entry, ip: '198.51.100.10', visitor_token: 'same-visitor') }

      expect(entry.reload).to be_status_suspect
      expect(entry.hits).to eq(5)
    end

    it 'старые ключи вне окна 24ч не считаются' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example', status: :suspect, source: 'local')
      stale = [{ 'ip' => '198.51.100.1', 'at' => 2.days.ago.iso8601 },
               { 'ip' => '198.51.100.2', 'at' => 2.days.ago.iso8601 }]
      entry.update_columns(hit_tokens: stale)

      described_class.record_hit!(entry, ip: '198.51.100.3', visitor_token: 'new-1')
      expect(entry.reload).to be_status_suspect
    end

    it 'blocked-запись не меняет статус от hits' do
      entry = described_class.create!(entry_type: :domain, value: 'known-spam.example', status: :blocked, source: 'local')

      4.times { |i| described_class.record_hit!(entry, ip: "198.51.100.#{i}", visitor_token: "v-#{i}") }

      expect(entry.reload).to be_status_blocked
    end

    it 'кворум не автоблокирует служебные записи фидов (шортенеры — только эвристика)' do
      entry = described_class.create!(entry_type: :domain, value: 'bit.ly',
                                      status: :suspect, source: 'hagezi_shorteners')

      %w[198.51.100.10 198.51.100.11 198.51.100.12].each do |ip|
        described_class.record_hit!(entry, ip: ip, visitor_token: 'v-x')
      end

      expect(entry.reload).to be_status_suspect
    end
  end

  describe '.ip_blocked?' do
    it 'точное совпадение по IP' do
      described_class.create!(entry_type: :ip, value: '203.0.113.66', status: :blocked, source: 'ipsum_l3')

      expect(described_class.ip_blocked?('203.0.113.66')).to be(true)
      expect(described_class.ip_blocked?('203.0.113.67')).to be(false)
      expect(described_class.ip_blocked?(nil)).to be(false)
    end

    it 'CIDR-подсеть из firehol-фида ловит хост внутри (botscout отдаёт и /31)' do
      Rails.cache.delete(described_class::CIDR_CACHE_KEY)
      described_class.create!(entry_type: :ip, value: '198.51.100.0/28', status: :blocked, source: 'firehol_botscout')

      expect(described_class.ip_blocked?('198.51.100.7')).to be(true)
      expect(described_class.ip_blocked?('198.51.100.20')).to be(false)
    end

    it 'мусорный IP не падает' do
      expect(described_class.ip_blocked?('not-an-ip')).to be(false)
    end
  end

  describe '.block_locally!' do
    it 'голый домен → domain-запись, blocked, source local' do
      result = described_class.block_locally!('WWW.Evil-Example.com')

      expect(result[:ok]).to be(true)
      entry = result[:value]
      expect(entry).to be_entry_type_domain
      expect(entry).to be_status_blocked
      expect(entry.source).to eq('local')
      expect(entry.value).to eq('evil-example.com')
      expect(entry.blocked_at).to be_present
    end

    it 'URL с путём → url-запись host+path (блок одной страницы, не хоста)' do
      result = described_class.block_locally!('https://t.me/spam_channel?utm_source=x')

      expect(result[:ok]).to be(true)
      entry = result[:value]
      expect(entry).to be_entry_type_url
      expect(entry.value).to eq('t.me/spam_channel')
    end

    it 'IDN-омограф пишется punycode-ключом: тот же ключ, что у фильтра' do
      result = described_class.block_locally!('http://sberbаnk.ru/login') # «а» кириллическая

      expect(result[:ok]).to be(true)
      expect(result[:value].value).to start_with('xn--')
    end

    it 'идемпотентен: повторный вызов не плодит записи' do
      described_class.block_locally!('botmasterru.com')

      expect { described_class.block_locally!('botmasterru.com') }
        .not_to change(described_class, :count)
    end

    it 'фидовая suspect-запись становится local blocked и больше не владение синка' do
      entry = described_class.create!(entry_type: :domain, value: 'fishy.example',
                                      status: :suspect, source: 'hagezi_tif')

      result = described_class.block_locally!('fishy.example')

      expect(result[:value].id).to eq(entry.id)
      expect(entry.reload).to be_status_blocked
      expect(entry.source).to eq('local')
    end

    it 'soft-deleted запись реанимируется local-записью' do
      entry = described_class.create!(entry_type: :domain, value: 'back.example',
                                      status: :blocked, source: 'phishing_domains')
      entry.update_columns(deleted_at: Time.current)

      result = described_class.block_locally!('back.example')

      expect(result[:ok]).to be(true)
      expect(result[:value]).to be_status_blocked
      expect(described_class.find_by(value: 'back.example')).to eq(result[:value])
    end

    it 'ручной suspect: новый домен в карантин с source local' do
      result = described_class.block_locally!('watch.example', status: :suspect)

      expect(result[:ok]).to be(true)
      expect(result[:value]).to be_status_suspect
      expect(result[:value].blocked_at).to be_nil
    end

    it 'мусорный вход → ok false, запись не создаётся' do
      result = described_class.block_locally!('not a url')

      expect(result[:ok]).to be(false)
      expect(result[:error]).to eq(:invalid_url)
    end

    it 'невалидный статус → ok false' do
      result = described_class.block_locally!('evil.example', status: :nope)

      expect(result[:ok]).to be(false)
      expect(result[:error]).to eq(:invalid_status)
    end
  end
end
