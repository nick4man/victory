# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversation do
  describe '#test_probe? (issue #214)' do
    it 'true для visitor_token с префиксом probe-' do
      expect(described_class.new(visitor_token: 'probe-maria-1211').test_probe?).to be(true)
    end

    it 'false для обычного токена и nil' do
      expect(described_class.new(visitor_token: 'aabbccddeeff00112233445566778899').test_probe?).to be(false)
      expect(described_class.new(visitor_token: nil).test_probe?).to be(false)
    end

    it 'поддельный префикс в середине токена не считается' do
      expect(described_class.new(visitor_token: 'xxprobe-123').test_probe?).to be(false)
    end
  end

  describe '#auto_test? / #lead_test_mode? (issue #227)' do
    it 'auto_test? читается из metadata' do
      expect(described_class.new(metadata: { 'auto_test' => true }).auto_test?).to be(true)
      expect(described_class.new(metadata: {}).auto_test?).to be(false)
      expect(described_class.new(metadata: nil).auto_test?).to be(false)
    end

    it 'lead_test_mode? — probe-тумблер ИЛИ auto-test ИЛИ ENV-кран' do
      expect(described_class.new(visitor_token: 'probe-widget').lead_test_mode?).to be(true)
      expect(described_class.new(metadata: { 'auto_test' => true }).lead_test_mode?).to be(true)

      old = ENV.fetch('SITE_CHATBOT_FORCE_TEST', nil)
      ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
      expect(described_class.new(visitor_token: 'plain-token').lead_test_mode?).to be(true)
    ensure
      old.nil? ? ENV.delete('SITE_CHATBOT_FORCE_TEST') : ENV['SITE_CHATBOT_FORCE_TEST'] = old
    end

    it 'боевой диалог (всё выключено) — lead_test_mode? false' do
      old = ENV.fetch('SITE_CHATBOT_FORCE_TEST', nil)
      ENV.delete('SITE_CHATBOT_FORCE_TEST')

      conv = described_class.new(visitor_token: 'plain-token', metadata: {})
      expect(conv.lead_test_mode?).to be(false)
    ensure
      old.nil? ? ENV.delete('SITE_CHATBOT_FORCE_TEST') : ENV['SITE_CHATBOT_FORCE_TEST'] = old
    end
  end
end
