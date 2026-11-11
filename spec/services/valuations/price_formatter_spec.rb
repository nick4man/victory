# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valuations::PriceFormatter do
  it 'форматирует рублёвые суммы с разделителями тысяч и ₽' do
    expect(described_class.format_rub(5_100_000)).to eq('5 100 000 ₽')
    expect(described_class.format_rub(4_800_000)).to eq('4 800 000 ₽')
    expect(described_class.format_rub(900)).to eq('900 ₽')
  end

  it 'nil / пусто → длинное тире' do
    expect(described_class.format_rub(nil)).to eq('—')
    expect(described_class.format_rub('')).to eq('—')
  end
end
