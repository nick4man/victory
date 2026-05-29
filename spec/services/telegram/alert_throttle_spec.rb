# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::AlertThrottle do
  # Чистим Redis ключи перед каждым тестом чтобы не наводить из предыдущих.
  before do
    redis_url = ENV['REDIS_URL'].presence || 'redis://localhost:6379/0'
    redis = Redis.new(url: redis_url)
    redis.scan_each(match: 'alert_throttle:test_*') { |k| redis.del(k) }
  rescue StandardError
    # Redis down — тесты fail-open path всё равно валидны
  end

  describe '.allow? — legacy (default WINDOW)' do
    it 'первый вызов = true' do
      expect(described_class.allow?(key: 'test_first_call')).to be true
    end

    it 'второй вызов в том же окне = false' do
      described_class.allow?(key: 'test_storm')
      expect(described_class.allow?(key: 'test_storm')).to be false
    end

    it 'инкрементит suppressed counter при подавлении' do
      described_class.allow?(key: 'test_counter')
      3.times { described_class.allow?(key: 'test_counter') }
      expect(described_class.suppressed_count(key: 'test_counter')).to eq(3)
    end
  end

  describe '.allow? — custom ttl (Phase 16.7)' do
    it 'принимает ttl: kwarg' do
      expect {
        described_class.allow?(key: 'test_custom_ttl', ttl: 24.hours)
      }.not_to raise_error
    end

    it 'после первого вызова с ttl=24h следующий = false (даже если 5min прошло — в окне)' do
      described_class.allow?(key: 'test_long_throttle', ttl: 24.hours)
      expect(described_class.allow?(key: 'test_long_throttle', ttl: 24.hours)).to be false
    end

    it 'дефолт ttl остаётся WINDOW для backward compat' do
      # Не падает без ttl кваргa
      expect(described_class.allow?(key: 'test_bc')).to be true
      expect(described_class.allow?(key: 'test_bc')).to be false
    end
  end

  describe '.allow? — Redis down' do
    it 'fail-open (return true) если Redis недоступен' do
      allow_any_instance_of(described_class).to receive(:connection).and_return(nil)
      expect(described_class.allow?(key: 'test_redis_down')).to be true
    end
  end
end
