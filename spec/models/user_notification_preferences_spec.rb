# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'User notification preferences (#435)' do
  let(:user) { create(:user, :tg_linked, phone: '+79991234567', email: 'a@b.com') }

  describe '#notify?' do
    context 'with default preferences (notification_settings nil или legacy)' do
      it 'inquiry_status → email + tg по дефолту' do
        expect(user.notify?(category: 'inquiry_status', channel: 'email')).to be(true)
        expect(user.notify?(category: 'inquiry_status', channel: 'tg')).to be(true)
        expect(user.notify?(category: 'inquiry_status', channel: 'sms')).to be(false)
      end

      it 'deal_events → все три канала включены' do
        expect(user.notify?(category: 'deal_events', channel: 'email')).to be(true)
        expect(user.notify?(category: 'deal_events', channel: 'tg')).to be(true)
        expect(user.notify?(category: 'deal_events', channel: 'sms')).to be(true)
      end

      it 'market_news / agency_news — выключены по дефолту (opt-in)' do
        expect(user.notify?(category: 'market_news', channel: 'email')).to be(false)
        expect(user.notify?(category: 'agency_news', channel: 'tg')).to be(false)
      end
    end

    context 'edge cases' do
      it 'unknown category → false' do
        expect(user.notify?(category: 'unknown', channel: 'email')).to be(false)
      end

      it 'unknown channel → false' do
        expect(user.notify?(category: 'inquiry_status', channel: 'fax')).to be(false)
      end

      it 'tg channel но user БЕЗ tg_user_id → false' do
        unlinked = create(:user, phone: '+79991234567', email: 'x@y.com')
        unlinked.update_columns(tg_user_id: nil)
        expect(unlinked.notify?(category: 'deal_events', channel: 'tg')).to be(false)
      end

      it 'email channel но user без email → false' do
        u = create(:user, phone: '+79991234567')
        u.update_columns(email: '') # email empty
        expect(u.notify?(category: 'deal_events', channel: 'email')).to be(false)
      end
    end

    context 'after #update_notification_pref' do
      it 'выключает inquiry_status:email' do
        user.update_notification_pref(category: 'inquiry_status', channel: 'email', enabled: false)
        expect(user.reload.notify?(category: 'inquiry_status', channel: 'email')).to be(false)
        # Другие каналы остаются по дефолту
        expect(user.notify?(category: 'inquiry_status', channel: 'tg')).to be(true)
      end

      it 'включает opt-in market_news:email' do
        user.update_notification_pref(category: 'market_news', channel: 'email', enabled: true)
        expect(user.reload.notify?(category: 'market_news', channel: 'email')).to be(true)
      end
    end
  end

  describe '#update_notification_pref' do
    it 'отвергает unknown category' do
      expect(user.update_notification_pref(category: 'unknown', channel: 'email', enabled: true)).to be(false)
    end

    it 'отвергает unknown channel' do
      expect(user.update_notification_pref(category: 'inquiry_status', channel: 'fax', enabled: true)).to be(false)
    end
  end

  describe 'integration с CabinetInvitationDispatcher' do
    let(:property) { nil }

    before do
      allow(CabinetInvitationMailer).to receive(:invite)
        .and_return(instance_double(ActionMailer::MessageDelivery, deliver_later: true))
    end

    it 'skips email когда deal_events:email = false' do
      user.update!(invited_at: nil)
      user.update_notification_pref(category: 'deal_events', channel: 'email', enabled: false)

      result = CabinetInvitationDispatcher.call(user, property, channels: %i[email])
      expect(result.channels_attempted).to be_empty
      expect(CabinetInvitationMailer).not_to have_received(:invite)
    end

    it 'отправляет email когда deal_events:email = true (default)' do
      user.update!(invited_at: nil)
      result = CabinetInvitationDispatcher.call(user, property, channels: %i[email])
      expect(result.channels_succeeded).to eq([:email])
    end
  end
end
