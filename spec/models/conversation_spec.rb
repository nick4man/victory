# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversation do
  describe '#test_probe? (issue #214, #229)' do
    it 'true при metadata["test_probe"] == true' do
      conv = described_class.new(visitor_token: 'aabbccddeeff00112233445566778899',
                                 metadata: { 'test_probe' => true })
      expect(conv.test_probe?).to be(true)
    end

    it 'false без маркера в metadata и для обычного токена' do
      expect(described_class.new(visitor_token: 'aabbccddeeff00112233445566778899').test_probe?).to be(false)
      expect(described_class.new(visitor_token: 'probe-maria-1211').test_probe?).to be(false)
      expect(described_class.new(visitor_token: nil).test_probe?).to be(false)
    end

    it 'false если metadata не Hash' do
      conv = described_class.new(visitor_token: 'abc', metadata: nil)
      expect(conv.test_probe?).to be(false)
    end
  end
end
