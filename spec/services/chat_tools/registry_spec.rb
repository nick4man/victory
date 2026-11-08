# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Registry do
  describe '.schemas' do
    it 'содержит list_mortgage_programs с валидной схемой' do
      schema = described_class.schemas.find { |s| s.dig(:function, :name) == 'list_mortgage_programs' }

      expect(schema).not_to be_nil
      expect(schema[:type]).to eq('function')
      expect(schema.dig(:function, :parameters, :type)).to eq('object')
      expect(schema.dig(:function, :description)).to be_present
    end
  end

  describe '.call' do
    it 'диспатчит list_mortgage_programs по имени' do
      allow(Mortgage::ProgramsService).to receive(:all).and_return([])

      expect(described_class.call('list_mortgage_programs', {})).to include(error: 'programs_unavailable')
    end
  end
end
