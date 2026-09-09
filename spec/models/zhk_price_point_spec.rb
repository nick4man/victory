# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ZhkPricePoint do
  it 'различает цену «от» и медиану — без этого ряд несравним сам с собой' do
    complex = create(:residential_complex)
    point = described_class.create!(residential_complex: complex, source: 'erz',
                                    observed_at: Time.current, price_per_sqm: 65_000,
                                    kind: :from)

    expect(point.kind_from?).to be true
    expect(point.kind_median?).to be false
  end
end
