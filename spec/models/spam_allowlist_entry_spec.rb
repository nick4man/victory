# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SpamAllowlistEntry do
  describe '.allowlisted?' do
    it 'точное совпадение по домену' do
      described_class.create!(domain: 't.me')

      expect(described_class.allowlisted?('t.me')).to be(true)
      expect(described_class.allowlisted?('evil-t.me')).to be(false)
      expect(described_class.allowlisted?('sub.t.me')).to be(false)
    end

    it 'nil/пустые значения не падают' do
      expect(described_class.allowlisted?(nil)).to be(false)
      expect(described_class.allowlisted?('')).to be(false)
    end
  end
end
