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
                visitor_token: 'visitor-abc', rate_limit: 3, now: Time.current,
                require_render_token: true)
    described_class.new(
      form: form, honeypot: honeypot, rendered_at: rendered_at_token, ip: ip,
      visitor_token: visitor_token, rate_limit: rate_limit, now: now,
      require_render_token: require_render_token
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

  # #262: эндпоинты без живой формы (PropertiesController#report) — тайминговые
  # сигналы выключены, остальные работают.
  describe 'require_render_token: false (эндпоинты без формы)' do
    it 'пропускает сабмит без timestamp рендера' do
      expect(gate_call(require_render_token: false).spam).to be false
    end

    it 'по-прежнему дропает honeypot и IP из блэклиста' do
      expect(gate_call(honeypot: 'x', require_render_token: false).reason).to eq 'honeypot'

      SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '203.0.113.10', source: 'firehol')
      expect(gate_call(require_render_token: false).reason).to eq 'spam_ip'
    end

    it 'по-прежнему режет rate limit' do
      Rails.cache.write(described_class.rate_limit_key('review', '203.0.113.10'), 3, expires_in: 1.hour)
      expect(gate_call(require_render_token: false).reason).to eq 'rate_limit'
    end
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

    it 'reserve_rate_limit_slot! атомарно резервирует слот и идемпотентен внутри инстанса' do
      gate = described_class.new(form: 'review', honeypot: '', rendered_at: nil, ip: '5.6.7.8',
                                 visitor_token: 'v')
      expect(gate.reserve_rate_limit_slot!).to be true
      # Повторный вызов на success-пути не инкрементирует счётчик дважды.
      expect(gate.reserve_rate_limit_slot!).to be true
      expect(Rails.cache.read(described_class.rate_limit_key('review', '5.6.7.8')).to_i).to eq 1
    end

    it 'reserve_rate_limit_slot! возвращает false сверх лимита' do
      Rails.cache.write(described_class.rate_limit_key('review', '5.6.7.8'), 3, expires_in: 1.hour)
      gate = described_class.new(form: 'review', honeypot: '', rendered_at: nil, ip: '5.6.7.8',
                                 visitor_token: 'v')
      expect(gate.reserve_rate_limit_slot!).to be false
    end

    it 'release_rate_limit_slot! освобождает зарезервированный слот' do
      gate = described_class.new(form: 'review', honeypot: '', rendered_at: nil, ip: '5.6.7.8',
                                 visitor_token: 'v')
      gate.reserve_rate_limit_slot!
      gate.release_rate_limit_slot!
      expect(Rails.cache.read(described_class.rate_limit_key('review', '5.6.7.8')).to_i).to eq 0

      # Повторный release — no-op: чужой слот не откатывается.
      gate.release_rate_limit_slot!
      expect(Rails.cache.read(described_class.rate_limit_key('review', '5.6.7.8')).to_i).to eq 0
    end

    it 'release_submission_markers! освобождает и маркер идемпотентности, и слот' do
      token = described_class.rendered_at_token(Time.current - 10.seconds)
      gate = described_class.new(form: 'review', honeypot: '', rendered_at: token, ip: '5.6.7.8',
                                 visitor_token: 'visitor-full-release')
      gate.call
      expect(Rails.cache.read(described_class.idempotency_key('review', 'visitor-full-release'))).to be true
      expect(Rails.cache.read(described_class.rate_limit_key('review', '5.6.7.8')).to_i).to eq 1

      gate.release_submission_markers!
      expect(Rails.cache.read(described_class.idempotency_key('review', 'visitor-full-release'))).to be_nil
      expect(Rails.cache.read(described_class.rate_limit_key('review', '5.6.7.8')).to_i).to eq 0
    end

    # Блокер 3 из ревью #262: связка «проверка счётчика в call, инкремент после
    # save» обходилась параллельным флудом. Резервация атомарна: из N
    # конкурентных сабмитов лимит превышают не более rate_limit.
    it 'конкурентные резервации не превышают лимит (гонка флуда)' do
      results = Array.new(10) do
        Thread.new do
          described_class.new(form: 'review', honeypot: '', rendered_at: nil, ip: '5.6.7.8',
                              visitor_token: 'v').reserve_rate_limit_slot!
        end
      end.map(&:value)

      expect(results.count(true)).to eq 3
      expect(Rails.cache.read(described_class.rate_limit_key('review', '5.6.7.8')).to_i).to eq 10
    end

    it 'дубль после резервации освобождает слот: двойной клик не жжёт квоту' do
      token = described_class.rendered_at_token(Time.current - 10.seconds)
      gate_call(rendered_at_token: token, visitor_token: 'visitor-dup')
      expect(Rails.cache.read(described_class.rate_limit_key('review', '203.0.113.10')).to_i).to eq 1

      result = gate_call(rendered_at_token: described_class.rendered_at_token(Time.current - 10.seconds),
                         visitor_token: 'visitor-dup')
      expect(result.reason).to eq 'duplicate'
      expect(Rails.cache.read(described_class.rate_limit_key('review', '203.0.113.10')).to_i).to eq 1
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

  # issue #286: нетерминальные дропы пишут hit в локальную репутацию IP;
  # кворум дропов за окно автоблочит адрес раньше фидовых блэклистов.
  describe 'автоблок IP по дропам гейта (issue #286)' do
    let(:flood_ip) { '203.0.113.99' }

    it 'IP с 5 дроп-событиями rate_limit за час → SpamBlockedEntry (local/blocked), следующий сабмит — spam_ip' do
      5.times { described_class.record(form: 'review', reason: 'rate_limit', ip: flood_ip, ua: 'Bot/1.0') }

      entry = SpamBlockedEntry.find_by(entry_type: :ip, value: flood_ip)
      expect(entry).to be_status_blocked
      expect(entry.source).to eq('local')

      result = gate_call(ip: flood_ip, rendered_at_token: token)
      expect(result.spam).to be true
      expect(result.reason).to eq 'spam_ip'
    end

    it 'honeypot и spam_ip не пишут hits — они терминальные' do
      described_class.record(form: 'review', reason: 'honeypot', ip: flood_ip, ua: 'Bot/1.0')
      described_class.record(form: 'review', reason: 'spam_ip', ip: flood_ip, ua: 'Bot/1.0')

      expect(SpamBlockedEntry.where(entry_type: :ip, value: flood_ip)).to be_empty
    end

    it 'одиночный rate_limit-дроп НЕ банит — запись остаётся suspect' do
      described_class.record(form: 'review', reason: 'rate_limit', ip: flood_ip, ua: 'Bot/1.0')

      entry = SpamBlockedEntry.find_by(entry_type: :ip, value: flood_ip)
      expect(entry).to be_status_suspect
      expect(SpamBlockedEntry.ip_blocked?(flood_ip)).to be false
    end

    it 'квота-окно не роняет легитимного клиента: 3 сабмита/час по лимиту не пишут hits' do
      3.times do |i|
        result = gate_call(ip: flood_ip, visitor_token: "visitor-legit-#{i}",
                           rendered_at_token: described_class.rendered_at_token(Time.current - 10.seconds))
        expect(result.spam).to be false
      end

      # счётчик дропа ≠ счётчику сабмитов: успешные сабмиты hits не создают
      expect(SpamBlockedEntry.where(entry_type: :ip, value: flood_ip)).to be_empty
    end

    it 'дропы каждой формы идут в общую репутацию IP (form не часть ключа)' do
      3.times { described_class.record(form: 'review', reason: 'rate_limit', ip: flood_ip, ua: 'Bot/1.0') }
      2.times { described_class.record(form: 'callback', reason: 'too_fast', ip: flood_ip, ua: 'Bot/1.0') }

      expect(SpamBlockedEntry.find_by(entry_type: :ip, value: flood_ip)).to be_status_blocked
    end
  end
end
