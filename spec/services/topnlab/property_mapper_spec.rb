# frozen_string_literal: true

require 'rails_helper'

# Coverage for Topnlab room-encoding parsing fix (18.05.26).
# Прежний эвристический `rooms > 9 → "Студия"` помечал ВСЕ объекты
# студиями, потому что Topnlab `rooms` — enum-id кратный 10 (10=Студия,
# 20=1ком, 30=2ком, …). Подробнее: .claude/docs/topnlab/listings-and-mls.md §3a.
RSpec.describe Topnlab::PropertyMapper do
  let(:base_payload) do
    {
      'id'           => 100_000_001,
      'realty_type'  => 'flat',
      'price'        => 5_000_000,
      'area_common'  => 50.0,
      'street_type'  => 'ул.',
      'street_name'  => 'Тестовая',
      'house'        => '1'
    }
  end

  def attrs_for(extra)
    described_class.new(base_payload.merge(extra)).to_attributes
  end

  describe '#sane_rooms' do
    it 'maps id=10 → 0 (студия)' do
      expect(attrs_for('rooms' => 10)[:rooms]).to eq(0)
    end

    it 'maps id=20 → 1 комната' do
      expect(attrs_for('rooms' => 20)[:rooms]).to eq(1)
    end

    it 'maps id=30 → 2 комнаты (user-reported 65.6 м² apartment)' do
      expect(attrs_for('rooms' => 30)[:rooms]).to eq(2)
    end

    it 'maps id=50 → 4 комнаты' do
      expect(attrs_for('rooms' => 50)[:rooms]).to eq(4)
    end

    it 'maps id=205 → 20 (cap at 20+)' do
      expect(attrs_for('rooms' => 205)[:rooms]).to eq(20)
    end

    it 'returns nil for free-planning code (99)' do
      expect(attrs_for('rooms' => 99)[:rooms]).to be_nil
    end

    it 'returns nil for unknown rooms id' do
      expect(attrs_for('rooms' => 17)[:rooms]).to be_nil
    end

    it 'returns nil for missing rooms' do
      expect(attrs_for('rooms' => nil)[:rooms]).to be_nil
    end

    it 'returns nil for realty_type=room regardless of rooms id' do
      expect(attrs_for('realty_type' => 'room', 'rooms' => 50, 'room_type' => 1)[:rooms]).to be_nil
    end
  end

  describe '#sane_rooms — area_room fallback' do
    it 'derives 3 from "19.1+6.7+6.6" when rooms enum is nil' do
      expect(attrs_for('rooms' => nil, 'area_room' => '19.1+6.7+6.6')[:rooms]).to eq(3)
    end

    it 'derives 2 from "15.3+12"' do
      expect(attrs_for('rooms' => nil, 'area_room' => '15.3+12')[:rooms]).to eq(2)
    end

    it 'returns nil when area_room blank' do
      expect(attrs_for('rooms' => nil, 'area_room' => '')[:rooms]).to be_nil
    end

    it 'ignores fallback for realty_type=room' do
      expect(attrs_for('realty_type' => 'room', 'rooms' => nil, 'area_room' => '15+10')[:rooms]).to be_nil
    end

    it 'prefers explicit enum over fallback' do
      # rooms=30 means «2-комн.» — should win over a 3-piece area_room
      expect(attrs_for('rooms' => 30, 'area_room' => '5+5+5')[:rooms]).to eq(2)
    end
  end

  describe '#build_title (через :title attribute)' do
    it 'titles студию как "Студия, …"' do
      title = attrs_for('rooms' => 10)[:title]
      expect(title).to start_with('Студия,')
      expect(title).to include('50 м²')
    end

    it 'titles 2-комн. как "2-комн. квартира, …"' do
      title = attrs_for('rooms' => 30)[:title]
      expect(title).to start_with('2-комн. квартира,')
    end

    it 'titles 4-комн. как "4-комн. квартира, …"' do
      title = attrs_for('rooms' => 50)[:title]
      expect(title).to start_with('4-комн. квартира,')
    end

    it 'titles free-planning' do
      title = attrs_for('rooms' => 99)[:title]
      expect(title).to start_with('Свободная планировка,')
    end

    it 'titles комнату в общежитии' do
      title = attrs_for('realty_type' => 'room', 'rooms' => 50, 'room_type' => 1)[:title]
      expect(title).to start_with('Комната в общежитии,')
    end

    it 'titles комнату в коммуналке' do
      title = attrs_for('realty_type' => 'room', 'rooms' => 50, 'room_type' => 2)[:title]
      expect(title).to start_with('Комната в коммунальной квартире,')
    end

    it 'не добавляет «квартира» суффикс к self-contained labels' do
      # Студия / Комната в общежитии — уже содержат указание типа
      [10, 99].each do |rooms_id|
        title = attrs_for('rooms' => rooms_id)[:title]
        expect(title).not_to include('Студия квартира')
        expect(title).not_to include('Свободная планировка квартира')
      end
    end
  end

  describe 'regression: old bug — rooms>9 не должно автоматом = "Студия"' do
    it 'rooms=20 (1-комн) НЕ титлится как Студия' do
      title = attrs_for('rooms' => 20)[:title]
      expect(title).not_to start_with('Студия')
      expect(title).to start_with('1-комн. квартира,')
    end

    it 'rooms=50 (4-комн) НЕ титлится как Студия' do
      expect(attrs_for('rooms' => 50)[:title]).not_to start_with('Студия')
    end
  end
end
