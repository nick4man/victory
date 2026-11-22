# frozen_string_literal: true

require 'rails_helper'

# Chat::TestMode (issue #249) — приоритет сигналов и разбор доверенных
# origin/IP. Request-спеки end-to-end поведения — в
# spec/requests/chat/test_mode_spec.rb, здесь — юнитная часть.
RSpec.describe Chat::TestMode do
  def result_for(headers: {}, remote_ip: nil, probe_cookie: false)
    request = instance_double(ActionDispatch::Request)
    hdrs = {}
    allow(request).to receive(:headers) { hdrs }
    allow(request).to receive(:remote_ip).and_return(remote_ip || '8.8.8.8')
    hdrs.replace(headers.transform_keys(&:to_s))

    described_class.new(request: request, probe_cookie: probe_cookie).call
  end

  around do |example|
    old = {
      'SITE_CHATBOT_FORCE_TEST' => ENV['SITE_CHATBOT_FORCE_TEST'],
      'CHAT_TEST_TRUSTED_ORIGINS' => ENV['CHAT_TEST_TRUSTED_ORIGINS'],
      'CHAT_TEST_TRUSTED_IPS' => ENV['CHAT_TEST_TRUSTED_IPS']
    }
    old.each_key { |k| ENV[k] = nil }
    example.run
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  it 'probe-cookie побеждает всё — приоритет из #228' do
    ENV['SITE_CHATBOT_FORCE_TEST'] = '0'
    r = result_for(headers: { 'Origin' => 'https://victory62.org' }, probe_cookie: true)

    expect(r.test?).to be(true)
    expect(r.reason).to eq(described_class::PROBE_COOKIE)
  end

  it 'кран ENV приоритетнее origin/IP' do
    ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
    r = result_for(headers: { 'Origin' => 'https://victory62.org' }, remote_ip: '176.104.221.64')

    expect(r.test?).to be(true)
    expect(r.reason).to eq(described_class::FORCE_ENV)
  end

  it 'origin приоритетнее IP' do
    r = result_for(headers: { 'Origin' => 'https://staging.dev.victory62.org' }, remote_ip: '8.8.8.8')

    expect(r.reason).to eq(described_class::TRUSTED_ORIGIN)
  end

  it 'боевой визит без сигналов — не тест' do
    r = result_for(headers: { 'Origin' => 'https://victory62.org' }, remote_ip: '176.104.221.64')

    expect(r.test?).to be(false)
    expect(r.reason).to be_nil
  end

  it 'IPv6-loopback (::1) — как localhost в origin-сигнале' do
    r = result_for(headers: { 'Origin' => 'http://[::1]:3000' })

    expect(r.test?).to be(true)
  end

  it 'пустой Origin не матчится как доверенный' do
    r = result_for(headers: { 'Origin' => '' })

    expect(r.test?).to be(false)
  end

  it 'битый URI в Origin — не падает, не доверенный' do
    r = result_for(headers: { 'Origin' => 'https://exa mple.com:80' })

    expect(r.test?).to be(false)
  end

  it 'большие буквы хоста нормализуются' do
    r = result_for(headers: { 'Origin' => 'https://STAGING.dev.victory62.org' })

    expect(r.test?).to be(true)
  end
end
