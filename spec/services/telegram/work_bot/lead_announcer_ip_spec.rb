# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::LeadAnnouncer do
  let(:inquiry) { create(:inquiry, source: 'site_form') }
  let(:client) { instance_double(Telegram::Client) }

  def build_lead(metadata)
    LeadEvent.create!(
      lead_ref:         inquiry,
      source:           'site_form',
      tg_chat_id:       -1_003_779_115_845,
      anchor_topic_key: 'dispatcher',
      current_stage:    'new',
      metadata:         metadata
    )
  end

  describe 'IP и user_agent источника на карточке (issue #275)' do
    it 'показывает IP и user_agent, когда они есть в meta' do
      lead = build_lead(
        'name' => 'Бот', 'ip' => '80.94.95.202',
        'user_agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0'
      )
      text = described_class.new(lead, client: client).format_card_text

      expect(text).to include('🌐 IP: 80.94.95.202 · Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0')
    end

    it 'показывает только IP, когда user_agent отсутствует' do
      lead = build_lead('name' => 'Бот', 'ip' => '80.94.95.202')
      text = described_class.new(lead, client: client).format_card_text

      expect(text).to include('🌐 IP: 80.94.95.202')
      expect(text).not_to include('🌐 IP: 80.94.95.202 ·')
    end

    it 'экранирует HTML в user_agent' do
      lead = build_lead('name' => 'Бот', 'ip' => '80.94.95.202', 'user_agent' => '<script>alert(1)</script>')
      text = described_class.new(lead, client: client).format_card_text

      expect(text).to include('&lt;script&gt;')
      expect(text).not_to include('<script>')
    end

    it 'обрезает длинный user_agent' do
      lead = build_lead('name' => 'Бот', 'ip' => '80.94.95.202', 'user_agent' => "Mozilla/5.0 #{'x' * 200}")
      text = described_class.new(lead, client: client).format_card_text

      expect(text).not_to include('x' * 100)
    end

    it 'опускает строку IP для лидов без него (TG-источники)' do
      lead = build_lead('name' => 'Клиент', 'phone' => '+790****4567')
      text = described_class.new(lead, client: client).format_card_text

      expect(text).not_to include('🌐 IP:')
    end
  end
end
