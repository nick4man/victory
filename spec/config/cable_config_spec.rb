# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'config/cable.yml' do
  # Регрессия 04.11.26: `pool:` в production-секции ронял ActionCable.server.broadcast
  # (redis-client не принимает неизвестные ключи) — чат сайта отвечал 500.
  it 'production-конфиг принимается клиентом Redis' do
    all = ActiveSupport::ConfigurationFile.parse(Rails.root.join('config/cable.yml'))
    cfg = all.fetch('production').except('adapter', 'channel_prefix').symbolize_keys
    cfg[:url] = 'redis://localhost:6379/1'

    expect { Redis.new(**cfg) }.not_to raise_error
  end
end
