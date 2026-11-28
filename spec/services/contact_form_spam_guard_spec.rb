# frozen_string_literal: true

require 'rails_helper'

# Антиспам-гейт формы /contacts (issue #239). Honeypot — единственный
# признак молчаливого дропа. Тайминговые причины
# (нет timestamp, слишком быстро) помечают заявку как
# suspicious, но не теряют без следа.
RSpec.describe ContactFormSpamGuard do
  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_cache
    travel_back
  end

  def guard_call(honeypot: '', rendered_at: 10.seconds.ago.to_f, now: Time.current, ip: nil)
    described_class.new(honeypot: honeypot, rendered_at: rendered_at, now: now, ip: ip).call
  end

  it 'пропускает нормальную отправку' do
    result = guard_call
    expect(result.spam).to be false
    expect(result.suspicious).to be false
    expect(result.reason).to be_nil
  end

  it 'дропает заполненный honeypot независимо от тайминга' do
    result = guard_call(honeypot: 'http://buy-cheap-links.example')
    expect(result.spam).to be true
    expect(result.suspicious).to be false
    expect(result.reason).to eq 'honeypot'
  end

  it 'дропает honeypot с пробельным мусором' do
    expect(guard_call(honeypot: '  ').spam).to be false
    expect(guard_call(honeypot: ' x ').reason).to eq 'honeypot'
  end

  it 'считает подозрительным POST без timestamp рендера' do
    result = guard_call(rendered_at: nil)
    expect(result.spam).to be false
    expect(result.suspicious).to be true
    expect(result.reason).to eq 'no_render_timestamp'
  end

  it 'считает подозрительной отправку быстрее MIN_FILL_SECONDS после рендера' do
    result = guard_call(rendered_at: (described_class::MIN_FILL_SECONDS - 1).seconds.ago.to_f)
    expect(result.spam).to be false
    expect(result.suspicious).to be true
    expect(result.reason).to eq 'too_fast'
  end

  it 'пропускает отправку ровно на границе MIN_FILL_SECONDS' do
    result = guard_call(rendered_at: described_class::MIN_FILL_SECONDS.seconds.ago.to_f)
    expect(result.spam).to be false
    expect(result.suspicious).to be false
  end

  it 'REASONS покрывает все отдаваемые причины' do
    expect(described_class::REASONS).to contain_exactly('honeypot', 'no_render_timestamp', 'too_fast', 'spam_ip')
  end

  describe 'IP-блэклист (issue #255)' do
    let(:blocked_ip) { '80.94.95.173' }

    before do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: blocked_ip, source: 'firehol')
    end

    it 'дропает submit с IP из блэклиста' do
      result = guard_call(ip: blocked_ip)
      expect(result.spam).to be true
      expect(result.suspicious).to be false
      expect(result.reason).to eq 'spam_ip'
    end

    it 'дропает submit с IP из CIDR-подсети блэклиста' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.0/24', source: 'firehol')
      result = guard_call(ip: '80.94.95.202')
      expect(result.spam).to be true
      expect(result.reason).to eq 'spam_ip'
    end

    it 'пропускает submit с чистым IP' do
      result = guard_call(ip: '203.0.113.10')
      expect(result.spam).to be false
      expect(result.suspicious).to be false
    end

    it 'пропускает submit без IP (blank — не повод дропать)' do
      result = guard_call(ip: nil)
      expect(result.spam).to be false
    end

    it 'считает spam_ip дропом (kind dropped) в логе record' do
      allow(Rails.logger).to receive(:info)
      described_class.record(reason: 'spam_ip', ip: blocked_ip, ua: 'Bot/1.0')
      expect(Rails.logger).to have_received(:info) do |message|
        expect(message).to include('reason=spam_ip')
        expect(message).to include('spam dropped')
      end
    end
  end

  describe 'подписанный timestamp рендера' do
    it 'генерирует и верифицирует токен' do
      now = Time.current
      token = described_class.rendered_at_token(now)
      expect(described_class.verify_rendered_at_token(token)).to be_within(0.001).of(now.to_f)
    end

    it 'возвращает nil для невалидного или пустого токена' do
      expect(described_class.verify_rendered_at_token(nil)).to be_nil
      expect(described_class.verify_rendered_at_token('')).to be_nil
      expect(described_class.verify_rendered_at_token('tampered-token')).to be_nil
    end

    it 'возвращает nil при нестроковом параметре (hash/array)' do
      expect(described_class.verify_rendered_at_token({ 'x' => 'y' })).to be_nil
      expect(described_class.verify_rendered_at_token(['x'])).to be_nil
    end
  end

  describe 'stateless CSRF-токен формы' do
    let(:binding_same) { ['visitor-123', 'fp-abc'] }
    let(:binding_other) { ['visitor-999', 'fp-xyz'] }

    it 'генерирует и верифицирует токен при совпадении binding' do
      token = described_class.form_csrf_token(binding_same)
      expect(described_class.verify_form_csrf_token(token, binding_same)).to be true
    end

    it 'принимает токен, если совпадает visitor_token даже при другом fingerprint' do
      token = described_class.form_csrf_token(['visitor-123', 'fp-old'])
      expect(described_class.verify_form_csrf_token(token, ['visitor-123', 'fp-new'])).to be true
    end

    it 'принимает токен, если совпадает fingerprint даже при другом visitor_token' do
      token = described_class.form_csrf_token(['visitor-old', 'fp-abc'])
      expect(described_class.verify_form_csrf_token(token, ['visitor-new', 'fp-abc'])).to be true
    end

    it 'не истекает: старый токен остаётся валидным' do
      token = travel_to(1.day.ago) { described_class.form_csrf_token(binding_same) }
      expect(described_class.verify_form_csrf_token(token, binding_same)).to be true
    end

    it 'отклоняет пустой, нестроковый или подделанный токен' do
      expect(described_class.verify_form_csrf_token(nil, binding_same)).to be false
      expect(described_class.verify_form_csrf_token('', binding_same)).to be false
      expect(described_class.verify_form_csrf_token('tampered', binding_same)).to be false
      expect(described_class.verify_form_csrf_token({ 'x' => 'y' }, binding_same)).to be false
    end

    it 'отклоняет токен другого клиента' do
      token = described_class.form_csrf_token(binding_same)
      expect(described_class.verify_form_csrf_token(token, binding_other)).to be false
    end
  end

  describe 'счётчики и алерты' do
    it 'инкрементирует счётчик по reason' do
      key = described_class.counter_key('honeypot')
      expect { described_class.record(reason: 'honeypot', ip: '1.2.3.4', ua: 'Bot/1.0') }
        .to change { Rails.cache.read(key).to_i }.by(1)
    end

    it 'задаёт TTL счётчику в один час' do
      key = described_class.counter_key('honeypot')
      described_class.record(reason: 'honeypot', ip: '1.2.3.4', ua: 'Bot')
      travel 2.hours
      expect(Rails.cache.read(key)).to be_nil
    end

    context 'c RedisCacheStore (production-семантика)' do
      around do |example|
        original_cache = Rails.cache
        redis_cache = ActiveSupport::Cache::RedisCacheStore.new(
          url: ENV.fetch('REDIS_URL', 'redis://redis:6379/1')
        )
        redis_cache.clear
        Rails.cache = redis_cache
        example.run
        Rails.cache = original_cache
      end

      it 'инкрементирует атомарно и задаёт TTL' do
        key = described_class.counter_key('honeypot')
        described_class.record(reason: 'honeypot', ip: '1.2.3.4', ua: 'Bot')

        raw_value = Rails.cache.redis.with { |c| c.get(key) }
        expect(raw_value).to eq('1')
        ttl = Rails.cache.redis.with { |c| c.ttl(key) }
        expect(ttl).to be_positive
      end
    end

    it 'логирует alert при превышении порога только один раз за окно' do
      threshold = described_class::ALERT_THRESHOLD
      allow(Rails.logger).to receive(:warn)

      threshold.times { described_class.record(reason: 'too_fast', ip: '1.2.3.4', ua: 'Bot') }
      expect(Rails.logger).to have_received(:warn).once

      described_class.record(reason: 'too_fast', ip: '1.2.3.4', ua: 'Bot')
      expect(Rails.logger).to have_received(:warn).once
    end

    it 'не логирует alert повторно, даже если маркер уже стоит' do
      described_class.send(:mark_alert_fired, 'honeypot')
      allow(Rails.logger).to receive(:warn)

      described_class.record(reason: 'honeypot', ip: '1.2.3.4', ua: 'Bot')
      described_class.record(reason: 'honeypot', ip: '1.2.3.4', ua: 'Bot')

      expect(Rails.logger).not_to have_received(:warn)
    end

    it 'санитизирует \r\n в user-agent перед логированием' do
      allow(Rails.logger).to receive(:info)
      malicious_ua = "Bot\r\nX-Injected: true\n"

      described_class.record(reason: 'honeypot', ip: '1.2.3.4', ua: malicious_ua)

      expect(Rails.logger).to have_received(:info) do |message|
        expect(message).not_to include("\r")
        expect(message).not_to include("\n")
        expect(message).to include('X-Injected: true')
      end
    end
  end

  # issue #286: нетерминальные сигналы пишут hit в локальную репутацию IP —
  # тот же паттерн, что PublicFormSpamGate::IP_HIT_REASONS.
  describe 'hits локальной репутации IP (issue #286)' do
    let(:ip) { '203.0.113.60' }

    it 'тайминговые причины (too_fast/no_render_timestamp) пишут hit' do
      described_class.record(reason: 'too_fast', ip: ip, ua: 'Bot/1.0')
      described_class.record(reason: 'no_render_timestamp', ip: ip, ua: 'Bot/1.0')

      entry = SpamBlockedEntry.find_by(entry_type: :ip, value: ip)
      expect(entry).to be_status_suspect
      expect(entry.source).to eq('local')
      expect(entry.hits).to eq(2)
    end

    it 'honeypot и spam_ip не пишут hits — они терминальные' do
      described_class.record(reason: 'honeypot', ip: ip, ua: 'Bot/1.0')
      described_class.record(reason: 'spam_ip', ip: ip, ua: 'Bot/1.0')

      expect(SpamBlockedEntry.where(entry_type: :ip, value: ip)).to be_empty
    end

    it 'кворум тайминговых сигналов автоблочит адрес' do
      SpamBlockedEntry::IP_GATE_QUORUM.times do
        described_class.record(reason: 'too_fast', ip: ip, ua: 'Bot/1.0')
      end

      entry = SpamBlockedEntry.find_by(entry_type: :ip, value: ip)
      expect(entry).to be_status_blocked
      expect(SpamBlockedEntry.ip_blocked?(ip)).to be true
    end
  end
end
