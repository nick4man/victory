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
end
