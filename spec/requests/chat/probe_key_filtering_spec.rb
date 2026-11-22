# frozen_string_literal: true

require 'rails_helper'

# Регрессия блокера ревью PR #250 (Kimi round 1, issue #249): параметр
# probe_key — это либо CHAT_PROBE_SECRET, либо (fallback) ADMIN_TOKEN.
# Раньше он не совпадал ни с одним фильтром → секрет мог уехать в
# Rails-логи и Sentry breadcrumbs в открытом виде.
RSpec.describe 'Фильтрация probe_key (issue #249)' do
  # Минимальный fake Sentry-event: scrub_pii! работает с любым объектом,
  # отвечающим на request/extra/contexts/user.
  FakeEvent = Struct.new(:request, :extra, :contexts, :user)

  it 'probe_key входит в Rails filter_parameters' do
    expect(Rails.application.config.filter_parameters).to include(:probe_key)
  end

  it 'scrub_pii! (Sentry before_send) затирает probe_key в event-хэшах' do
    secret = 'super-secret-probe-key-value'
    event = FakeEvent.new(
      nil,
      { 'probe_key' => secret, 'nested' => { 'probe_key' => secret }, 'other' => 'keep me' },
      nil,
      nil
    )
    # scrub_pii! определён в config/initializers/sentry.rb на top-level
    # (main Object) и доступен без SENTRY_DSN.
    scrub_pii!(event)

    expect(event.extra['probe_key']).to eq('[FILTERED]')
    expect(event.extra['nested']['probe_key']).to eq('[FILTERED]')
    expect(event.extra['other']).to eq('keep me')
  end
end
