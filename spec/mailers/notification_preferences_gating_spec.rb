# frozen_string_literal: true

require 'rails_helper'

# Integration spec — verify что skip_unless_notify! фактически блокирует
# доставку email. В test env emails captured в ActionMailer::Base.deliveries.
# Если perform_deliveries=false — email НЕ добавляется в deliveries.
RSpec.describe 'Notification preferences gating in mailers (#436)' do
  let(:user) { create(:user, email: 'test@example.com') }

  before { ActionMailer::Base.deliveries.clear }

  describe 'CabinetMailer.stage_update' do
    let(:inquiry) { create(:inquiry) }
    let(:lead) do
      LeadEvent.create!(
        lead_ref: inquiry, source: 'tg_dm', current_stage: 'show',
        anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_message_id: 1234
      )
    end

    it 'отправляет когда inquiry_status:email = true (default)' do
      ActionMailer::Base.deliveries.clear
      CabinetMailer.stage_update(user, lead).deliver_now
      sent = ActionMailer::Base.deliveries.select { |m| m.subject.to_s.include?('Статус сделки') }
      expect(sent.size).to eq(1)
    end

    it 'НЕ отправляет когда user opted out' do
      user.update_notification_pref(category: 'inquiry_status', channel: 'email', enabled: false)
      ActionMailer::Base.deliveries.clear
      CabinetMailer.stage_update(user, lead).deliver_now
      sent = ActionMailer::Base.deliveries.select { |m| m.subject.to_s.include?('Статус сделки') }
      expect(sent.size).to eq(0)
    end
  end

  describe 'ListingConsentMailer.consent_required' do
    let(:property) do
      Property.unscoped.create!(
        title: 'Тестовая квартира для spec', address: 'Test addr',
        price: 1_000_000, area: 50, external_source: 'topnlab',
        external_id: 'spec-1', slug: 'spec-slug-1', status: 'active',
        user_id: user.id
      )
    end

    it 'отправляет document_requests:email = true (default)' do
      ActionMailer::Base.deliveries.clear
      ListingConsentMailer.consent_required(property, user).deliver_now
      sent = ActionMailer::Base.deliveries.select { |m| m.subject.to_s.include?('согласие') }
      expect(sent.size).to eq(1)
    end

    it 'НЕ отправляет когда opt-out' do
      user.update_notification_pref(category: 'document_requests', channel: 'email', enabled: false)
      ActionMailer::Base.deliveries.clear
      ListingConsentMailer.consent_required(property, user).deliver_now
      sent = ActionMailer::Base.deliveries.select { |m| m.subject.to_s.include?('согласие') }
      expect(sent.size).to eq(0)
    end
  end

  describe 'Auth mailers НЕ gate (essential security)' do
    let(:token) do
      MagicLinkToken.generate!(
        identifier: user.email, identifier_type: 'email', scope: 'login'
      )
    end

    it 'magic_link отправляется даже если ВСЁ opt-out' do
      User::NOTIFICATION_CATEGORIES.each do |cat|
        User::NOTIFICATION_CHANNELS.each do |ch|
          user.update_notification_pref(category: cat, channel: ch, enabled: false)
        end
      end
      expect { CabinetMailer.magic_link(user, token).deliver_now }
        .to change { ActionMailer::Base.deliveries.size }.by(1)
    end
  end

  describe 'User без registration (anonymous, e.g. one-off inquiry)' do
    it 'inquiry_confirmation отправляется даже без user (anonymous flow)' do
      inq = build(:inquiry, email: 'anon@example.com', message: 'Хочу квартиру в центре')
      inq.save!(validate: false)
      expect(inq.user).to be_nil
      ActionMailer::Base.deliveries.clear
      InquiryMailer.inquiry_confirmation(inq).deliver_now
      sent = ActionMailer::Base.deliveries.select { |m| m.subject.to_s.include?('Мы получили') }
      expect(sent.size).to eq(1)
    end
  end
end
