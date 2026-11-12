# frozen_string_literal: true

require 'rails_helper'

# Антиспам-гейт формы /contacts (issue #223). Honeypot + тайминг —
# оба сигнала прозрачны для человека, ловят наивных ботов.
RSpec.describe ContactFormSpamGuard do
  def check(honeypot: '', rendered_at: 10.seconds.ago.to_f, now: Time.current)
    described_class.check(honeypot: honeypot, rendered_at: rendered_at, now: now)
  end

  it 'пропускает нормальную отправку' do
    result = check
    expect(result.spam).to be false
    expect(result.reason).to be_nil
  end

  it 'дропает заполненный honeypot независимо от тайминга' do
    result = check(honeypot: 'http://buy-cheap-links.example')
    expect(result.spam).to be true
    expect(result.reason).to eq 'honeypot'
  end

  it 'дропает honeypot с пробельным мусором' do
    expect(check(honeypot: '  ').spam).to be false
    expect(check(honeypot: ' x ').reason).to eq 'honeypot'
  end

  it 'дропает POST без timestamp рендера (скрипт без визита на /contacts)' do
    result = check(rendered_at: nil)
    expect(result.spam).to be true
    expect(result.reason).to eq 'no_render_timestamp'
  end

  it 'дропает отправку быстрее MIN_FILL_SECONDS после рендера' do
    result = check(rendered_at: (described_class::MIN_FILL_SECONDS - 1).seconds.ago.to_f)
    expect(result.spam).to be true
    expect(result.reason).to eq 'too_fast'
  end

  it 'пропускает отправку ровно на границе MIN_FILL_SECONDS' do
    result = check(rendered_at: described_class::MIN_FILL_SECONDS.seconds.ago.to_f)
    expect(result.spam).to be false
  end

  it 'REASONS покрывает все отдаваемые причины' do
    expect(described_class::REASONS).to contain_exactly('honeypot', 'no_render_timestamp', 'too_fast')
  end
end
