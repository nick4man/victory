# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::SegmentKeyboard do
  let(:lead) { LeadEvent.new(id: 42) }

  it 'один ряд — по кнопке на каждый сегмент' do
    row = described_class.row(lead)
    expect(row.size).to eq(LeadEvent::SEGMENTS.size)
    expect(row.map { |b| b[:callback_data] }).to all(match(/\Asegment:42:[a-z_]+\z/))
  end

  it 'callback_data укладывается в лимит Telegram 64 байта' do
    described_class.row(lead).each { |b| expect(b[:callback_data].bytesize).to be <= 64 }
  end

  it '.for оборачивает ряд в inline_keyboard' do
    expect(described_class.for(lead)).to eq(inline_keyboard: [described_class.row(lead)])
  end

  it 'карточка, переехавшая в спец-топик, не уносит с собой кнопки маршрутизации' do
    moved = LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'new',
                              anchor_topic_key: 'dispatcher', tg_chat_id: -100_123)
    markup = Telegram::WorkBot::LeadAnnouncer.new(moved).keyboard_for_card('apartments')
    data = markup[:inline_keyboard].flatten.map { |b| b[:callback_data] }

    expect(data).to include("segment:#{moved.id}:cash")
    expect(data.grep(/\Aroute:/)).to be_empty
  end
end
