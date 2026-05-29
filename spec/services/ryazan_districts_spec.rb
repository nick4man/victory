# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RyazanDistricts do
  describe '.strip_folk_suffix' do
    it 'strips "(народный)" суффикс' do
      expect(described_class.strip_folk_suffix('Московский (народный)')).to eq('Московский')
    end

    it 'is whitespace tolerant' do
      expect(described_class.strip_folk_suffix('Московский ( народный )')).to eq('Московский')
      expect(described_class.strip_folk_suffix('Московский  (народный)  ')).to eq('Московский')
    end

    it 'is case-insensitive' do
      expect(described_class.strip_folk_suffix('Московский (Народный)')).to eq('Московский')
      expect(described_class.strip_folk_suffix('Московский (НАРОДНЫЙ)')).to eq('Московский')
    end

    it 'strips middle-of-string (для address fields)' do
      input = 'Рязанская обл., г. Рязань, Московский (народный), ул. Новаторов'
      expected = 'Рязанская обл., г. Рязань, Московский, ул. Новаторов'
      expect(described_class.strip_folk_suffix(input)).to eq(expected)
    end

    it 'returns input as-is when no folk suffix' do
      expect(described_class.strip_folk_suffix('Московский')).to eq('Московский')
      expect(described_class.strip_folk_suffix('Канищево')).to eq('Канищево')
    end

    it 'handles nil' do
      expect(described_class.strip_folk_suffix(nil)).to be_nil
    end

    it 'handles empty string' do
      expect(described_class.strip_folk_suffix('')).to eq('')
    end

    it 'does NOT touch unrelated parentheses' do
      expect(described_class.strip_folk_suffix('Москва (центр)')).to eq('Москва (центр)')
    end
  end

  describe 'aliases — "Московский (народный)" больше НЕ в списке' do
    it 'admin moskovskiy aliases — только canonical name' do
      expect(described_class::ADMIN['moskovskiy'][:aliases]).to eq(['Московский'])
    end

    it 'micro moskovskiy-mr aliases — без "(народный)" варианта' do
      aliases = described_class::MICRO['moskovskiy-mr'][:aliases]
      expect(aliases).not_to include('Московский (народный)')
      expect(aliases).to include('Московский', 'Московское шоссе')
    end
  end
end
