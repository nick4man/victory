# frozen_string_literal: true

require 'rails_helper'

# Общий антиспам-гейт публичных форм (issue #261). Все сигналы — молчаливые
# дропы: honeypot, IP из блэклиста (точный + CIDR), отсутствие/подделка
# timestamp рендера, слишком быстрое заполнение, rate limit, дубль по
# visitor_token. Образец — ContactFormSpamGuard (#239/#255), но suspicious-
# ветки нет: формы из #261 не создают записей из подозрительных сабмитов.
RSpec.describe PublicFormSpamGate do
  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_cache
    travel_back
  end

  def gate_call(form: 'review', honeypot: '', rendered_at_token: nil, ip: '203.0.113.10',
                visitor_token: 'visitor-abc', rate_limit: 3, now: Time.current)
    described_class.new(
      form: form, honeypot: honeypot, rendered_at: rendered_at_token, ip: ip,
      visitor_token: visitor_token, rate_limit: rate_limit, now: now
    ).call
  end

  let(:now) { Time.current }
  let(:token) { described_class.rendered_at_token(now - 10.seconds) }

  it 'пропускает нормальный сабмит' do
    result = gate_call(rendered_at_token: token, now: now.to_f)
    expect(result.spam).to be false
    expect(result.reason).to be_nil
  end

  it 'дропает заполненный honeypot' do
    result = gate_call(honeypot: 'http://buy-cheap-links.example', rendered_at_token: token)
    expect(result.spam).to be true
    expect(result.reason).to eq 'honeypot'
  end

  it 'не считает пробельный honeypot заполненным' do
    expect(gate_call(honeypot: '   ', rendered_at_token: token).spam).to be false
  end

  describe 'IP-блэклист (SpamBlockedEntry.ip_blocked?)' do
    let(:blocked_ip) { '80.94.95.173' }

    before do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: blocked_ip, source: 'firehol')
    end

    it 'дропает submit с IP из блэклиста (точное совпадение)' do
      result = gate_call(ip: blocked_ip, rendered_at_token: token)
      expect(result.spam).to be true
      expect(result.reason).to eq 'spam_ip'
    end

    it 'дропает submit с IP из CIDR-подсети блэклиста' do
      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '45.128.232.0/24', source: 'firehol')
      result = gate_call(ip: '45.128.232.202', rendered_at_token: token)
      expect(result.spam).to be true
      expect(result.reason).to eq 'spam_ip'
    end

    it 'пропускает submit с чистым IP' do
      result = gate_call(ip: '198.51.100.7', rendered_at_token: token)
      expect(result.spam).to be false
    end
  end

  describe 'timestamp рендера (verifier общий с /contacts)' do
    it 'дропает POST без токена' do
      result = gate_call(rendered_at_token: nil)
      expect(result.spam).to be true
      expect(result.reason).to eq 'no_render_timestamp'
    end

    it 'дропает POST с подделанным токеном' do
      result = gate_call(rendered_at_token: 'tampered')
      expect(result.spam).to be true
      expect(result.reason).to eq 'no_render_timestamp'
    end

    it 'дропает отправку быстрее MIN_FILL_SECONDS после рендера' do
      result = gate_call(rendered_at_token: described_class.rendered_at_token(now - 1.second), now: now.to_f)
      expect(result.spam).to be true
      expect(result.reason).to eq 'too_fast'
    end
  end

  describe 'rate limit' do
    it 'дропает сабмит сверх лимита' do
      3.times do |i|
        Rails.cache.write(described_class.rate_limit_key('review', '203.0.113.10'), i + 1, expires_in: 1.hour)
      end
      result = gate_call(rendered_at_token: token)
      expect(result.spam).to be true
      expect(result.reason).to eq 'rate_limit'
    end

    it 'учитывает лимит конкретной формы (ключи не пересекаются)' do
      Rails.cache.write(described_class.rate_limit_key('review', '203.0.113.10'), 3, expires_in: 1.hour)
      result = gate_call(form: 'callback', rendered_at_token: token)
      expect(result.spam).to be false
    end
  end

  describe 'идемпотентность по visitor_token' do
    it 'первый сабмит проходит, дубль в окне дропается' do
      expect(gate_call(rendered_at_token: token).spam).to be false
      result = gate_call(rendered_at_token: described_class.rendered_at_token(now - 10.seconds))
      expect(result.spam).to be true
      expect(result.reason).to eq 'duplicate'
    end

    it 'разные visitor_token не схлопываются' do
      gate_call(rendered_at_token: token, visitor_token: 'visitor-one')
      result = gate_call(rendered_at_token: described_class.rendered_at_token(now - 10.seconds),
                         visitor_token: 'visitor-two')
      expect(result.spam).to be false
    end

    it 'после истечения окна дубль снова проходит' do
      gate_call(rendered_at_token: token)
      travel described_class::IDEMPOTENCY_WINDOW + 1.minute
      result = gate_call(rendered_at_token: described_class.rendered_at_token(Time.current - 10.seconds))
      expect(result.spam).to be false
    end

    it 'пустой visitor_token не участвует в идемпотентности' do
      gate_call(rendered_at_token: token, visitor_token: nil)
      result = gate_call(rendered_at_token: described_class.rendered_at_token(now - 10.seconds),
                         visitor_token: '')
      expect(result.spam).to be false
    end
  end

  describe 'self.duplicate_submit? — атомарность маркера' do
    it 'конкурентные записи дают один true (unless_exist)' do
      first  = described_class.duplicate_submit?('review', 'visitor-x')
      second = described_class.duplicate_submit?('review', 'visitor-x')
      expect(first).to be false
      expect(second).to be true
    end
  end

  describe 'record — лог дропа (образец #255)' do
    it 'логирует dropped с reason, ip и санитизированным ua' do
      allow(Rails.logger).to receive(:info)
      described_class.record(form: 'review', reason: 'spam_ip', ip: '1.2.3.4', ua: "Bot\r\nInjected: 1")
      expect(Rails.logger).to have_received(:info) do |message|
        expect(message).to include('[public_form:review]')
        expect(message).to include('spam dropped')
        expect(message).to include('reason=spam_ip')
        expect(message).to include('ip=1.2.3.4')
        expect(message).not_to include("\r")
        expect(message).not_to include("\n")
      end
    end

    it 'не логирует неизвестный reason' do
      allow(Rails.logger).to receive(:info)
      described_class.record(form: 'review', reason: 'unknown', ip: '1.2.3.4', ua: 'Bot')
      expect(Rails.logger).not_to have_received(:info)
    end

    it 'логирует alert один раз за окно при превышении порога' do
      allow(Rails.logger).to receive(:warn)
      described_class::ALERT_THRESHOLD.times do
        described_class.record(form: 'review', reason: 'honeypot', ip: '1.2.3.4', ua: 'Bot')
      end
      expect(Rails.logger).to have_received(:warn).once

      described_class.record(form: 'review', reason: 'honeypot', ip: '1.2.3.4', ua: 'Bot')
      expect(Rails.logger).to have_received(:warn).once
    end
  end

  describe 'инстанс-обёртки' do
    it 'spam?/suspicious? после call' do
      gate = described_class.new(form: 'review', honeypot: 'x', rendered_at: nil, ip: '1.2.3.4',
                                 visitor_token: 'v')
      gate.call
      expect(gate).to be_spam
      expect(gate).not_to be_suspicious
      expect(gate.reason).to eq 'honeypot'
    end

    it 'release_idempotency_marker! освобождает зарезервированный маркер' do
      token = described_class.rendered_at_token(Time.current - 10.seconds)
      gate = described_class.new(form: 'review', honeypot: '', rendered_at: token, ip: '1.2.3.4',
                                 visitor_token: 'visitor-rel')
      gate.call
      expect(Rails.cache.read(described_class.idempotency_key('review', 'visitor-rel'))).to be true

      gate.release_idempotency_marker!
      expect(Rails.cache.read(described_class.idempotency_key('review', 'visitor-rel'))).to be_nil

      # После освобождения повтор проходит как первый сабмит.
      expect(described_class.duplicate_submit?('review', 'visitor-rel')).to be false
    end

    it 'release_idempotency_marker! без visitor_token — no-op' do
      gate = described_class.new(form: 'review', honeypot: '', rendered_at: nil, ip: '1.2.3.4',
                                 visitor_token: '')
      expect { gate.release_idempotency_marker! }.not_to raise_error
    end

    it 'record делегирует в класс-метод' do
      allow(described_class).to receive(:record)
      gate = described_class.new(form: 'review', honeypot: 'x', rendered_at: nil, ip: '1.2.3.4',
                                 visitor_token: 'v')
      gate.call
      gate.record(ua: 'Bot/1.0')
      expect(described_class).to have_received(:record)
        .with(form: 'review', reason: 'honeypot', ip: '1.2.3.4', ua: 'Bot/1.0')
    end

    it 'register_rate_limit_hit! инкрементирует счётчик формы' do
      gate = described_class.new(form: 'review', honeypot: '', rendered_at: nil, ip: '5.6.7.8',
                                 visitor_token: 'v')
      gate.register_rate_limit_hit!
      expect(Rails.cache.read(described_class.rate_limit_key('review', '5.6.7.8')).to_i).to eq 1
    end
  end

  describe 'rendered_at_token — переиспользование verifier /contacts' do
    it 'генерирует и верифицирует токен, совместимый с ContactFormSpamGuard' do
      now_value = Time.current
      token_value = described_class.rendered_at_token(now_value)
      expect(described_class.verify_rendered_at_token(token_value)).to be_within(0.001).of(now_value.to_f)
      expect(ContactFormSpamGuard.verify_rendered_at_token(token_value)).to be_within(0.001).of(now_value.to_f)
    end

    it 'HONEYPOT_PARAM общий с ContactFormSpamGuard' do
      expect(described_class::HONEYPOT_PARAM).to eq ContactFormSpamGuard::HONEYPOT_PARAM
    end
  end
end
