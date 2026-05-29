# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LeadEvent do
  let(:buyer_order) do
    BuyerOrder.create!(client_name: 'Test', deal_type: 'sale',
                       deal_state: 'lead', synced_at: Time.current)
  end

  def build_event(attrs = {})
    described_class.new({
      lead_ref:         buyer_order,
      source:           'site_form',
      tg_chat_id:       -1_003_779_115_845,
      anchor_topic_key: 'dispatcher',
      current_stage:    'new'
    }.merge(attrs))
  end

  describe 'validations' do
    it 'требует source из перечня' do
      e = build_event(source: 'unknown')
      expect(e).not_to be_valid
    end

    it 'требует anchor_topic_key из перечня' do
      e = build_event(anchor_topic_key: 'not_a_topic')
      expect(e).not_to be_valid
    end

    it 'требует tg_chat_id' do
      expect(build_event(tg_chat_id: nil)).not_to be_valid
    end
  end

  describe 'state predicates' do
    it 'open? для new/first_contact/show/contract/deal' do
      %w[new first_contact show contract deal].each do |stage|
        expect(build_event(current_stage: stage).open?).to be(true)
      end
    end

    it 'closed? только для closed_won/closed_lost' do
      expect(build_event(current_stage: 'closed_won').closed?).to be(true)
      expect(build_event(current_stage: 'closed_lost').closed?).to be(true)
      expect(build_event(current_stage: 'new').closed?).to be(false)
    end
  end

  describe '#anchor_url' do
    it 'строит t.me/c/ ссылку из chat_id (со срезом -100) + thread + msg' do
      e = build_event(tg_chat_id: -1_003_779_115_845, anchor_thread_id: 42, anchor_message_id: 7)
      expect(e.anchor_url).to eq('https://t.me/c/3779115845/42/7')
    end

    it 'nil если нет message_id или thread_id' do
      expect(build_event(anchor_message_id: nil, anchor_thread_id: 42).anchor_url).to be_nil
      expect(build_event(anchor_message_id: 1, anchor_thread_id: nil).anchor_url).to be_nil
    end
  end

  describe 'scopes' do
    let!(:open_event)  { build_event(current_stage: 'new').tap(&:save!) }
    let!(:won_event)   { build_event(current_stage: 'closed_won').tap(&:save!) }
    let!(:lost_event)  { build_event(current_stage: 'closed_lost').tap(&:save!) }

    it 'open исключает closed_*' do
      expect(described_class.open).to contain_exactly(open_event)
    end

    it 'closed только closed_won/closed_lost' do
      expect(described_class.closed).to contain_exactly(won_event, lost_event)
    end
  end
end
