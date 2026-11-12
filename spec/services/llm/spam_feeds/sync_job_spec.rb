# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::SpamFeeds::SyncJob do
  # adblock-формат hagezi: ||domain^; комментарии «!», исключения «@@||»,
  # модификаторы (...^$document) фильтруются парсером
  let(:tif_body) do
    <<~LIST
      [Adblock Plus]
      ! comment line
      ||spam-one.example^
      ||spam-two.example^
      ||Spam-Three.Example^
      ||except.me^$document
      @@||white.example^
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
    # порог правдоподобия в спеках = 1 запись, чтобы короткие стабы проходили
    stub_const('Llm::SpamFeeds::SyncJob::DOMAIN_FEEDS',
               described_class::DOMAIN_FEEDS.transform_values { |cfg| cfg.merge(min_rows: 1) })
    stub_const('Llm::SpamFeeds::SyncJob::IP_FEEDS',
               described_class::IP_FEEDS.transform_values { |cfg| cfg.merge(min_rows: 1) })

    # все фиды, кроме явно заданных в примерах — пустые ответы;
    # отдельные примеры переопределяют stub конкретного URL
    (described_class::DOMAIN_FEEDS.values + described_class::IP_FEEDS.values).each do |cfg|
      stub_request(:get, cfg[:url]).to_return(status: 200, body: '') if cfg[:url].present?
    end
    stub_request(:get, described_class::DOMAIN_FEEDS['hagezi_tif'][:url])
      .to_return(status: 200, body: tif_body)
    stub_request(:get, described_class::IP_FEEDS['ipsum_l3'][:url])
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
    # adblock-артефакты не попали в список
    expect(SpamBlockedEntry.find_by(value: 'except.me')).to be_nil
    expect(SpamBlockedEntry.find_by(value: 'white.example')).to be_nil
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

  it 'локальный suspect, подтверждённый blocked-фидом, повышается до blocked' do
    local = SpamBlockedEntry.create!(entry_type: :domain, value: 'promote-me.example',
                                     status: :suspect, source: 'local')
    stub_request(:get, described_class::DOMAIN_FEEDS['hagezi_tif'][:url])
      .to_return(status: 200, body: "||promote-me.example^\n||other-spam.example^\n")

    described_class.perform_now

    expect(local.reload).to be_status_blocked
    expect(local.blocked_at).to be_present
  end

  it 'протухание: запись, исчезнувшая из объединения фидов, soft-delete' do
    stale = SpamBlockedEntry.create!(entry_type: :domain, value: 'gone.example',
                                     status: :blocked, source: 'hagezi_tif')
    described_class.perform_now

    expect(stale.reload.deleted_at).to be_present
    expect(SpamBlockedEntry.find_by(value: 'spam-one.example')).to be_present
  end

  it 'пересечение фидов: ключ, оставшийся в другом успешном фиде, не протухает' do
    overlap = SpamBlockedEntry.create!(entry_type: :domain, value: 'overlap.example',
                                       status: :blocked, source: 'phishing_domains')
    stub_request(:get, described_class::DOMAIN_FEEDS['phishing_domains'][:url])
      .to_return(status: 200, body: "overlap.example\nother-phish.example\n")

    described_class.perform_now

    # tif в этом прогоне домен не отдаёт, но свежий phishing_domains — отдаёт
    expect(overlap.reload.deleted_at).to be_nil
  end

  it 'возврат ключа в фид реанимирует протухшую запись' do
    revived = SpamBlockedEntry.unscoped.create!(entry_type: :domain, value: 'spam-one.example',
                                                status: :blocked, source: 'hagezi_tif',
                                                deleted_at: 1.day.ago)
    described_class.perform_now

    expect(revived.reload.deleted_at).to be_nil
  end

  it 'пустой ответ фида не стирает прежние записи источника' do
    existing = SpamBlockedEntry.create!(entry_type: :domain, value: 'keep.example',
                                        status: :blocked, source: 'hagezi_tif')
    stub_request(:get, described_class::DOMAIN_FEEDS['hagezi_tif'][:url])
      .to_return(status: 200, body: '')

    stats = described_class.perform_now

    expect(stats['hagezi_tif']).to eq(0)
    expect(existing.reload.deleted_at).to be_nil
  end

  it 'резко усечённая НЕпустая выгрузка отклонена: записи источника целы' do
    stub_const('Llm::SpamFeeds::SyncJob::DOMAIN_FEEDS',
               described_class::DOMAIN_FEEDS.merge(
                 'hagezi_tif' => described_class::DOMAIN_FEEDS['hagezi_tif'].merge(min_rows: 100)
               ))
    existing = SpamBlockedEntry.create!(entry_type: :domain, value: 'keep.example',
                                        status: :blocked, source: 'hagezi_tif')
    stub_request(:get, described_class::DOMAIN_FEEDS['hagezi_tif'][:url])
      .to_return(status: 200, body: "||only-one.example^\n")

    stats = described_class.perform_now

    expect(stats['hagezi_tif']).to eq(0)
    expect(existing.reload.deleted_at).to be_nil
    expect(SpamBlockedEntry.find_by(value: 'only-one.example')).to be_nil
  end

  it 'падение одного фида не роняет остальные' do
    stub_request(:get, described_class::DOMAIN_FEEDS['hagezi_tif'][:url])
      .to_return(status: 500)

    stats = described_class.perform_now

    expect(stats['hagezi_tif']).to eq(0)
    expect(stats['ipsum_l3']).to eq(2)
  end

  it 'urlhaus без URLHAUS_EXPORT_URL пропускается молча (остальные работают)' do
    stats = described_class.perform_now

    expect(stats['urlhaus']).to eq(0)
    expect(stats['hagezi_tif']).to eq(3)
  end

  context 'phishing_links: полные URL, не домена' do
    before do
      stub_request(:get, described_class::DOMAIN_FEEDS['phishing_links'][:url])
        .to_return(status: 200, body: "https://shared-host.example/phish/login\nhttps://shared-host.example/other\n")
    end

    it 'пишет entry_type = url: блок одной страницы, не всего хоста' do
      described_class.perform_now

      entry = SpamBlockedEntry.find_by(entry_type: :url, value: 'shared-host.example/phish/login')
      expect(entry).to be_present
      expect(entry).to be_status_blocked
      # доменная запись из URL-фида не создаётся
      expect(SpamBlockedEntry.find_by(entry_type: :domain, value: 'shared-host.example')).to be_nil
    end

    it 'регрессия: blocked host/phish не блочит другой путь того же хоста' do
      described_class.perform_now
      SpamAllowlistEntry.create!(domain: 'shared-host.example', manual: true)

      clean = Llm::SpamFilter.classify('посмотрите https://shared-host.example/clean — нормально?',
                                       ip: '198.51.100.10', visitor_token: 'v-1')
      phish = Llm::SpamFilter.classify('войдите https://shared-host.example/phish/login',
                                       ip: '198.51.100.10', visitor_token: 'v-1')

      expect(clean[:action]).to eq(:pass)
      expect(phish[:action]).to eq(:drop)
    end

    it 'URL без пути из URL-фида не создаёт доменную запись: корень хоста URL-фиды не блочит' do
      stub_request(:get, described_class::DOMAIN_FEEDS['phishing_links'][:url])
        .to_return(status: 200, body: "https://root-only.example\nhttps://stays.example/x\n")

      described_class.perform_now

      # контракт: URL-фид пишет только полные host+path; корень хоста — работа
      # доменных фидов, иначе одна фишинговая запись без пути блочила бы домен
      expect(SpamBlockedEntry.find_by(entry_type: :domain, value: 'root-only.example')).to be_nil
      expect(SpamBlockedEntry.find_by(entry_type: :url, value: 'stays.example/x'))
        .to have_attributes(status: 'blocked', source: 'phishing_links')

      # следующий прогон: stays остаётся в фиде — запись не протухает
      stub_request(:get, described_class::DOMAIN_FEEDS['phishing_links'][:url])
        .to_return(status: 200, body: "https://stays.example/x\n")
      described_class.perform_now

      expect(SpamBlockedEntry.find_by(entry_type: :url, value: 'stays.example/x')).to be_present
    end
  end

  context 'urlhaus' do
    let(:urlhaus_url) { 'https://urlhaus-api.abuse.ch/v2/files/exports/KEY/text' }

    before do
      stub_const('Llm::SpamFeeds::SyncJob::URLHAUS_FEED',
                 'urlhaus' => { url: urlhaus_url, format: :urls, entry_type: :url, min_rows: 1 })
    end

    it 'с ключом: импортирует полные URL и протухает их безопасно' do
      stub_request(:get, urlhaus_url)
        .to_return(status: 200, body: "http://malware.example/payload.exe\nhttp://malware.example/second\n")

      described_class.perform_now

      expect(SpamBlockedEntry.find_by(entry_type: :url, value: 'malware.example/payload.exe'))
        .to have_attributes(status: 'blocked', source: 'urlhaus')

      # повторный прогон со сбоем URLhaus не стирает прежние записи фида
      stub_request(:get, urlhaus_url).to_return(status: 500)
      described_class.perform_now

      expect(SpamBlockedEntry.unscoped.find_by(entry_type: :url, value: 'malware.example/payload.exe'))
        .to have_attributes(deleted_at: nil)
    end
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

  it 'усечённая выгрузка allowlist (zip ниже порога) не стирает рабочий список' do
    stub_const('Llm::SpamFeeds::SyncJob::ALLOWLIST_MIN_ROWS', 3)
    SpamAllowlistEntry.create!(domain: 'keep-me.example')
    stub_request(:get, described_class::ALLOWLIST_URL)
      .to_return(status: 200, body: File.binread(Rails.root.join('spec/fixtures/files/tranco-small.zip')))

    described_class.perform_now

    expect(SpamAllowlistEntry.allowlisted?('keep-me.example')).to be(true)
    expect(SpamAllowlistEntry.allowlisted?('only-one.example')).to be(false)
  end

  it 'Tranco отвечает 307 на /download/… — fetch следует редиректам' do
    stub_const('Llm::SpamFeeds::SyncJob::ALLOWLIST_MIN_ROWS', 3)
    daily_url = 'https://tranco-list.eu/download/daily/current-list.zip'
    stub_request(:get, described_class::ALLOWLIST_URL)
      .to_return(status: 307, body: '', headers: { 'location' => '/download/daily/current-list.zip' })
    stub_request(:get, daily_url).to_return(status: 200, body: allowlist_body)

    described_class.perform_now

    expect(SpamAllowlistEntry.allowlisted?('white-1.example')).to be(true)
  end

  it 'allowlist: домен, исчезнувший из Tranco, протухает (soft-delete)' do
    stub_const('Llm::SpamFeeds::SyncJob::ALLOWLIST_MIN_ROWS', 3)
    gone = SpamAllowlistEntry.create!(domain: 'gone-white.example')

    described_class.perform_now

    expect(gone.reload.deleted_at).to be_present
  end

  it 'падение середины импорта не протухает прежние записи фида' do
    # регрессия: chunk 1 записан, chunk 2 упал — источник не должен попасть
    # в synced, иначе retire_stale стёр бы записи необработанной части фида
    stub_const('Llm::SpamFeeds::SyncJob::BATCH', 1)
    old_entry = SpamBlockedEntry.create!(entry_type: :domain, value: 'keep.example',
                                         status: :blocked, source: 'hagezi_tif',
                                         seen_at: 2.days.ago)
    stub_request(:get, described_class::DOMAIN_FEEDS['hagezi_tif'][:url])
      .to_return(status: 200, body: "new-one.example\nnew-two.example\n")

    calls = 0
    allow(SpamBlockedEntry).to receive(:insert_all).and_wrap_original do |original, *args|
      calls += 1
      raise ActiveRecord::StatementInvalid, 'boom' if calls == 2

      original.call(*args)
    end

    stats = described_class.perform_now

    expect(stats['hagezi_tif']).to eq(0)
    expect(old_entry.reload.deleted_at).to be_nil
  end
end
