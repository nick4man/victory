# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeMethod -- второй аргумент describe группирует
# спеку по фиче (карточка объекта), а не по одному методу.
RSpec.describe CrmCards::Checker, 'карточка объекта' do
  let(:author) { TelegramUser.create!(tg_user_id: 98_961, status: 'active') }
  let(:flat) do
    { 'owner_name' => 'Иванов Пётр', 'owner_phone' => '79100001122', 'action' => 'sale', 'realty_type' => 'flat',
      'address' => 'Рязань, ул. Есенина, 29', 'price' => 5_500_000, 'area_common' => 54.3, 'area_living' => 30,
      'area_kitchen' => 9, 'rooms' => 2, 'floor' => 3, 'floors_total' => 5,
      'contract_type' => 'agent', 'contract_number' => 'А-17/26' }
  end

  def check(payload)
    described_class.call(CrmCard.new(kind: 'object', author: author, payload: payload))
  end

  it 'полная квартира — без замечаний' do
    expect(check(flat)).to eq([])
  end

  it 'общая площадь меньше суммы жилой и кухни' do
    expect(check(flat.merge('area_common' => 35))).to contain_exactly(
      a_hash_including('field' => 'area_common', 'message' => a_string_including('меньше суммы жилой и кухни (39 м²)'))
    )
  end

  it 'этаж выше этажности дома' do
    expect(check(flat.merge('floor' => 7))).to contain_exactly(
      a_hash_including('field' => 'floor', 'message' => 'Этаж 7 выше этажности дома (5).')
    )
  end

  it 'агентский договор без номера' do
    expect(check(flat.except('contract_number'))).to contain_exactly(
      a_hash_including('field' => 'contract_number', 'message' => a_string_including('нужен номер договора'))
    )
  end

  it 'устная договорённость номера не требует' do
    expect(check(flat.merge('contract_type' => 'verbal').except('contract_number'))).to eq([])
  end

  it 'квартира без числа комнат' do
    expect(check(flat.except('rooms'))).to contain_exactly(a_hash_including('field' => 'rooms'))
  end

  it 'участок: вместо общей площади — площадь участка' do
    land = flat.merge('realty_type' => 'land')
               .except('area_common', 'area_living', 'area_kitchen', 'rooms', 'floor', 'floors_total')

    expect(check(land)).to contain_exactly(a_hash_including('field' => 'area_land'))
    expect(check(land.merge('area_land' => 8))).to eq([])
  end

  it 'conditionally_required знает условия' do
    expect(described_class.conditionally_required('realty_type' => 'flat', 'contract_type' => 'ad_agreement'))
      .to eq(%w[area_common rooms contract_number])
    expect(described_class.conditionally_required('realty_type' => 'land')).to eq(%w[area_land])
    expect(described_class.conditionally_required({})).to eq([])
  end
end
# rubocop:enable RSpec/DescribeMethod
