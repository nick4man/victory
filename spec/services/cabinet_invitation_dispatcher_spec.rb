# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CabinetInvitationDispatcher do
  let(:property) { nil } # property не нужен для dispatch tests — он только в message

  describe 'channel priority' do
    context 'when user has email, tg, and phone' do
      let(:user) do
        create(:user, :tg_linked,
               email: 'test@example.com',
               phone: '+79091234567',
               invited_at: nil)
      end

      it 'prefers email — does not invoke TG or SMS' do
        # CabinetInvitationMailer.invite — заглушаем deliver_later
        mailer = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
        allow(CabinetInvitationMailer).to receive(:invite).and_return(mailer)
        allow(CabinetInvitationTgService).to receive(:call)
        allow(CabinetInvitationSmsService).to receive(:call)

        result = described_class.call(user, property)

        expect(result.channels_succeeded).to eq([:email])
        expect(CabinetInvitationMailer).to have_received(:invite).with(user, property)
        expect(CabinetInvitationTgService).not_to have_received(:call)
        expect(CabinetInvitationSmsService).not_to have_received(:call)
      end

      it 'sets invited_at after success' do
        mailer = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
        allow(CabinetInvitationMailer).to receive(:invite).and_return(mailer)

        described_class.call(user, property)
        expect(user.reload.invited_at).to be_within(2.seconds).of(Time.current)
      end
    end

    context 'when user has only TG + phone (no email)' do
      # Email column is NOT NULL in DB schema; stub email на runtime для
      # симуляции Topnlab phone-only clients.
      let(:user) do
        u = create(:user, :tg_linked, phone: '+79091234567', invited_at: nil)
        allow(u).to receive(:email).and_return(nil)
        u
      end

      it 'falls to TG, skips SMS on TG success' do
        allow(CabinetInvitationTgService).to receive(:call)
          .and_return(CabinetInvitationTgService::Result.new(success?: true, user: user, message_id: 999))
        allow(CabinetInvitationSmsService).to receive(:call)

        result = described_class.call(user, property)

        expect(result.channels_succeeded).to eq([:tg])
        expect(CabinetInvitationTgService).to have_received(:call).with(user, property)
        expect(CabinetInvitationSmsService).not_to have_received(:call)
      end

      it 'falls through to SMS when TG fails' do
        allow(CabinetInvitationTgService).to receive(:call)
          .and_return(CabinetInvitationTgService::Result.new(success?: false, user: user, error: 'tg unreachable'))
        allow(CabinetInvitationSmsService).to receive(:call)
          .and_return(double(success?: true, message_id: 'sms-1', cost: 1.5))

        result = described_class.call(user, property)

        expect(result.channels_attempted).to eq(%i[tg sms])
        expect(result.channels_succeeded).to eq([:sms])
        expect(result.errors.first).to include('tg unreachable')
      end
    end

    context 'when user has only phone' do
      let(:user) do
        u = create(:user, phone: '+79091234567', invited_at: nil)
        allow(u).to receive(:email).and_return(nil)
        u
      end

      it 'goes straight to SMS' do
        allow(CabinetInvitationSmsService).to receive(:call)
          .and_return(double(success?: true, message_id: 'sms-1', cost: 1.5))

        result = described_class.call(user, property)
        expect(result.channels_attempted).to eq([:sms])
        expect(result.channels_succeeded).to eq([:sms])
      end
    end
  end

  describe 'idempotency' do
    let(:user) { create(:user, email: 'x@y.com', invited_at: 1.hour.ago) }

    it 'short-circuits when invited_at already set' do
      allow(CabinetInvitationMailer).to receive(:invite)
      result = described_class.call(user, property)
      expect(result.channels_attempted).to be_empty
      expect(result.errors.first).to include('already invited')
      expect(CabinetInvitationMailer).not_to have_received(:invite)
    end
  end

  describe 'nil user' do
    it 'short-circuits without crashing' do
      result = described_class.call(nil, property)
      expect(result.errors).to include('user nil')
    end
  end

  describe 'stop-list pre-flight (152-ФЗ)' do
    let(:user) do
      create(:user, :tg_linked, email: 'a@b.com', phone: '+79009694844', invited_at: nil)
    end

    before { PhoneStopList.add!(phone: '+79009694844', reason: 'spam complaint') }

    it 'short-circuits ALL channels when phone is in stop-list' do
      allow(CabinetInvitationMailer).to receive(:invite)
      allow(CabinetInvitationTgService).to receive(:call)
      allow(CabinetInvitationSmsService).to receive(:call)

      result = described_class.call(user, property)
      expect(result.channels_attempted).to be_empty
      expect(result.errors.first).to include('stop-list')
      expect(CabinetInvitationMailer).not_to have_received(:invite)
      expect(CabinetInvitationTgService).not_to have_received(:call)
      expect(CabinetInvitationSmsService).not_to have_received(:call)
    end
  end

  describe 'channel override (channels:)' do
    let(:user) do
      create(:user, :tg_linked, email: 'a@b.com', phone: '+79091234567', invited_at: nil)
    end

    it 'force SMS-only when channels: [:sms]' do
      allow(CabinetInvitationSmsService).to receive(:call)
        .and_return(double(success?: true, message_id: 'sms-1', cost: 1.5))
      allow(CabinetInvitationMailer).to receive(:invite)

      result = described_class.call(user, property, channels: [:sms])
      expect(result.channels_attempted).to eq([:sms])
      expect(result.channels_succeeded).to eq([:sms])
      expect(CabinetInvitationMailer).not_to have_received(:invite)
    end
  end

  describe 'error isolation' do
    let(:user) { create(:user, :tg_linked, email: 'a@b.com', invited_at: nil) }

    it 'continues to TG when email raises' do
      allow(CabinetInvitationMailer).to receive(:invite).and_raise(StandardError, 'smtp down')
      allow(CabinetInvitationTgService).to receive(:call)
        .and_return(CabinetInvitationTgService::Result.new(success?: true, user: user, message_id: 1))

      result = described_class.call(user, property)
      expect(result.channels_attempted).to eq(%i[email tg])
      expect(result.channels_succeeded).to eq([:tg])
      expect(result.errors.first).to include('smtp down')
    end
  end
end
