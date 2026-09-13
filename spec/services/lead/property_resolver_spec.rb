# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lead::PropertyResolver do
  let(:property) { create(:property) }

  it 'Property как lead_ref → сам объект' do
    expect(described_class.for_ref(property)).to eq(property)
  end

  it 'Inquiry с property_id → объект заявки' do
    inquiry = create(:inquiry, property_id: property.id)
    expect(described_class.for_ref(inquiry)).to eq(property)
  end

  it 'Inquiry без property_id → nil' do
    expect(described_class.for_ref(create(:inquiry))).to be_nil
  end

  it 'ref без property_id (PropertyValuation) → nil, не падает' do
    ref = PropertyValuation.new
    expect(described_class.for_ref(ref)).to be_nil
  end

  it 'nil → nil' do
    expect(described_class.for_ref(nil)).to be_nil
  end

  it 'удалённый объект (deleted_at) всё равно резолвится — история показов не должна терять объект' do
    property.update_column(:deleted_at, Time.current)
    inquiry = create(:inquiry, property_id: property.id)
    expect(described_class.for_ref(inquiry)&.id).to eq(property.id)
  end
end
