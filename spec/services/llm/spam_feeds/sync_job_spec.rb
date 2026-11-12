# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::SpamFeeds::SyncJob do
  let(:feed_body) do
    <<~LIST
      # comment line
      spam-one.example
      spam-two.example

      Spam-Three.Example
    LIST
  end

  let(:ip_feed_body) do
    <<~LIST
      # ipset
      203.0.113.66
      198.51.100.7/32
    LIST
  end

  let(:allowlist_body) do
    File.binread(Rails.root.join('spec/fixtures/files/tranco-top.zip'))
  end

  before do
    # все фиды, кроме явно заданных в примерах — пустые ответы;
    # отдельные примеры переопределяют stub конкретного URL
    (described_class::DOMAIN_FEEDS.values + described_class::IP_FEEDS.values).each do |url|
      stub_request(:get, url).to_return(status: 200, body: '')
    end
    stub_request(:get, 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/tif.txt')
      .to_return(status: 200, body: feed_body)
    stub_request(:get, 'https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt')
      .to_return(status: 200, body: ip_feed_body)
    stub_request(:get, described_class::ALLOWLIST_URL)
      .to_return(status: 200, body: allowlist_body)
  end

  it 'забирает фиды, нормализует и кладёт blocked-записи с source фида' do
    stats = described_class.perform_now

    expect(SpamBlockedEntry.find_by(entry_type: :domain, value: 'spam-one.example'))
      .to have_attributes(status: 'blocked', source: 'hagezi_tif')
    expect(SpamBlockedEntry.find_by(entry_type: :domain, value: 'spam-three.example'))
      .to have_attributes(status: 'blocked', source: 'hagezi_tif')
    expect(SpamBlockedEntry.find_by(entry_type: :ip, value: '203.0.113.66'))
      .to have_attributes(status: 'blocked', source: 'ipsum_l3')
    expect(stats['hagezi_tif']).to eq(3)
    expect(stats['ipsum_l3']).to eq(2)
  end

  it 'идемпотентен: повторный прогон не плодит дубли' do
    described_class.perform_now
    expect { described_class.perform_now }.not_to change(SpamBlockedEntry, :count)
  end

  it 'не трогает локальные записи (source = local)' do
    local = SpamBlockedEntry.create!(entry_type: :domain, value: 'local-spam.example',
                                     status: :suspect, source: 'local')
    described_class.perform_now

    expect(local.reload).to be_status_suspect
    expect(local.source).to eq('local')
    expect(local.deleted_at).to be_nil
  end

  it 'протухание: запись источника, исчезнувшая из фида, soft-delete' do
    stale = SpamBlockedEntry.create!(entry_type: :domain, value: 'gone.example',
                                     status: :blocked, source: 'hagezi_tif')
    described_class.perform_now

    expect(stale.reload.deleted_at).to be_present
    expect(SpamBlockedEntry.find_by(value: 'spam-one.example')).to be_present
  end

  it 'пустой ответ фида не стирает прежние записи источника' do
    existing = SpamBlockedEntry.create!(entry_type: :domain, value: 'keep.example',
                                        status: :blocked, source: 'hagezi_tif')
    stub_request(:get, 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/tif.txt')
      .to_return(status: 200, body: '')

    stats = described_class.perform_now

    expect(stats['hagezi_tif']).to eq(0)
    expect(existing.reload.deleted_at).to be_nil
  end

  it 'падение одного фида не роняет остальные' do
    stub_request(:get, 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/tif.txt')
      .to_return(status: 500)

    stats = described_class.perform_now

    expect(stats['hagezi_tif']).to eq(0)
    expect(stats['ipsum_l3']).to eq(2)
  end

  it 'синкает allowlist (Tranco Top-10k snapshot)' do
    stub_const('Llm::SpamFeeds::SyncJob::ALLOWLIST_MIN_ROWS', 3)

    described_class.perform_now

    expect(SpamAllowlistEntry.where(manual: false).count).to eq(5)
    expect(SpamAllowlistEntry.allowlisted?('white-1.example')).to be(true)
  end

  it 'manual-записи allowlist (ручные исключения + наш домен) синк не стирает' do
    stub_const('Llm::SpamFeeds::SyncJob::ALLOWLIST_MIN_ROWS', 3)
    SpamAllowlistEntry.create!(domain: 'keep-me.example', manual: true)

    described_class.perform_now

    expect(SpamAllowlistEntry.unscoped.find_by(domain: 'keep-me.example')).to be_present
  end

  it 'усечённая выгрузка allowlist не стирает рабочий список' do
    stub_const('Llm::SpamFeeds::SyncJob::ALLOWLIST_MIN_ROWS', 3)
    SpamAllowlistEntry.create!(domain: 'keep-me.example')
    stub_request(:get, described_class::ALLOWLIST_URL)
      .to_return(status: 200, body: "1,only-one.example\n")

    described_class.perform_now

    expect(SpamAllowlistEntry.allowlisted?('keep-me.example')).to be(true)
    expect(SpamAllowlistEntry.allowlisted?('only-one.example')).to be(false)
  end
end
