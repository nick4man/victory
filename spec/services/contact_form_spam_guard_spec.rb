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

  def guard_call(honeypot: '', rendered_at: 10.seconds.ago.to_f, now: Time.current)
    described_class.new(honeypot: honeypot, rendered_at: rendered_at, now: now).call
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
    expect(described_class::REASONS).to contain_exactly('honeypot', 'no_render_timestamp', 'too_fast')
  end

  describe 'подписанный timestamp рендера' do
    it 'генерирует и верифицирует токен' do
      token = described_class.rendered_at_token(Time.current)
      expect(described_class.verify_rendered_at_token(token)).to be_within(0.001).of(Time.current.to_f)
    end

    it 'возвращает nil для невалидного или пустого токена' do
      expect(described_class.verify_rendered_at_token(nil)).to be_nil
      expect(described_class.verify_rendered_at_token('')).to be_nil
      expect(described_class.verify_rendered_at_token('tampered-token')).to be_nil
    end
  end

  describe 'счётчики и алерты' do
    it 'инкрементирует счётчик по reason' do
      key = described_class.counter_key('honeypot')
      expect { described_class.record(reason: 'honeypot', ip: '1.2.3.4', ua: 'Bot/1.0') }
        .to change { Rails.cache.read(key).to_i }.by(1)
    end

    it 'логирует alert при превышении порога только один раз за окно' do
      threshold = described_class::ALERT_THRESHOLD
      allow(Rails.logger).to receive(:warn)

      threshold.times { described_class.record(reason: 'too_fast', ip: '1.2.3.4', ua: 'Bot') }
      expect(Rails.logger).to have_received(:warn).once

      described_class.record(reason: 'too_fast', ip: '1.2.3.4', ua: 'Bot')
      expect(Rails.logger).to have_received(:warn).once
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
end
