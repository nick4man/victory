# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivationEvent do
  let(:user) { create(:user) }

  describe '.log!' do
    it 'creates ActivationEvent с channel + happened_at' do
      expect {
        described_class.log!(user: user, channel: 'inbound', metadata: { tg_user_id: 123 })
      }.to change { described_class.count }.by(1)

      ev = described_class.last
      expect(ev.user).to eq(user)
      expect(ev.channel).to eq('inbound')
      expect(ev.happened_at).to be_within(2.seconds).of(Time.current)
      expect(ev.metadata).to include('tg_user_id' => 123)
    end

    it 'захватывает ip_address когда передан' do
      described_class.log!(user: user, channel: 'admin_panel', ip_address: '203.0.113.1')
      expect(described_class.last.ip_address).to eq('203.0.113.1')
    end

    it 'не падает activation flow при DB ошибке (returns nil)' do
      allow(described_class).to receive(:create!).and_raise(StandardError, 'db hiccup')
      result = described_class.log!(user: user, channel: 'inbound')
      expect(result).to be_nil # graceful degradation
    end

    it 'validates channel inclusion' do
      expect {
        described_class.create!(user: user, channel: 'unknown', happened_at: Time.current)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe '.channel_breakdown' do
    before do
      create(:activation_event, :inbound,         user: user, happened_at: 2.days.ago)
      create(:activation_event, :inbound,         user: user, happened_at: 1.day.ago)
      create(:activation_event, :cabinet_profile, user: user, happened_at: 1.day.ago)
      create(:activation_event, :admin_panel,     user: user, happened_at: 8.days.ago) # вне 7-day window
    end

    it 'aggregates по channel + total за 7 дней' do
      r = described_class.channel_breakdown(range: 7.days.ago..Time.current)
      expect(r['inbound']).to eq(2)
      expect(r['cabinet_profile']).to eq(1)
      expect(r['admin_panel']).to eq(0)
      expect(r['bulk_pdf']).to eq(0)
      expect(r['total']).to eq(3) # admin_panel из 8 days ago — вне range
    end

    it 'все CHANNELS присутствуют в breakdown (с 0 если нет данных)' do
      r = described_class.channel_breakdown(range: 1.hour.ago..Time.current)
      described_class::CHANNELS.each { |c| expect(r).to have_key(c) }
    end
  end

  describe 'scopes' do
    let!(:recent_ev) { create(:activation_event, user: user, happened_at: 1.hour.ago) }
    let!(:old_ev)    { create(:activation_event, user: user, happened_at: 30.days.ago) }
    let!(:inb_ev)    { create(:activation_event, :inbound, user: user, happened_at: 1.day.ago) }
    let!(:bulk_ev)   { create(:activation_event, :bulk_pdf, user: user, happened_at: 1.day.ago) }

    it '.recent(period) filters' do
      result = described_class.recent(7.days)
      expect(result).to include(recent_ev, inb_ev, bulk_ev)
      expect(result).not_to include(old_ev)
    end

    it '.by_channel filters' do
      expect(described_class.by_channel('inbound')).to include(inb_ev)
      expect(described_class.by_channel('inbound')).not_to include(bulk_ev)
    end
  end
end
