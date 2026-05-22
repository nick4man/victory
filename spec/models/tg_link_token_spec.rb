# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TgLinkToken do
  describe '.generate!' do
    let(:user) { create(:user) }

    it 'creates a valid token tied to user' do
      tok = described_class.generate!(user: user)
      expect(tok).to be_persisted
      expect(tok.user).to eq(user)
      expect(tok.token.length).to be >= 40
      expect(tok.expires_at).to be > 29.minutes.from_now
    end

    it 'captures audit fields when request present' do
      request = instance_double('ActionDispatch::Request',
                                remote_ip: '203.0.113.42',
                                user_agent: 'TestBrowser/1.0')
      tok = described_class.generate!(user: user, request: request)
      expect(tok.ip_address).to eq('203.0.113.42')
      expect(tok.user_agent).to eq('TestBrowser/1.0')
    end

    it 'each token is unique' do
      a = described_class.generate!(user: user)
      b = described_class.generate!(user: user)
      expect(a.token).not_to eq(b.token)
    end
  end

  describe 'scope .valid' do
    let(:user) { create(:user) }
    let!(:fresh)    { create(:tg_link_token, user: user) }
    let!(:expired)  { create(:tg_link_token, :expired, user: user) }
    let!(:consumed) { create(:tg_link_token, :consumed, user: user) }

    it 'includes only un-consumed and not-expired tokens' do
      expect(described_class.valid).to include(fresh)
      expect(described_class.valid).not_to include(expired, consumed)
    end
  end

  describe '.consume!' do
    let(:user) { create(:user) }
    let(:tok)  { create(:tg_link_token, user: user) }

    it 'links tg account on happy path' do
      linked_user, err = described_class.consume!(
        raw_token: tok.token, tg_user_id: 12_345, tg_username: '@johndoe'
      )
      expect(err).to be_nil
      expect(linked_user).to eq(user)
      expect(user.reload.tg_user_id).to eq(12_345)
      expect(user.tg_username).to eq('johndoe') # @-prefix stripped
      expect(user.tg_linked_at).to be_within(2.seconds).of(Time.current)
    end

    it 'marks token consumed' do
      described_class.consume!(raw_token: tok.token, tg_user_id: 12_345)
      expect(tok.reload.consumed_at).to be_within(2.seconds).of(Time.current)
    end

    it 'returns :not_found for blank token' do
      _, err = described_class.consume!(raw_token: nil, tg_user_id: 1)
      expect(err).to eq(:not_found)
    end

    it 'returns :not_found for unknown token' do
      _, err = described_class.consume!(raw_token: 'wrong', tg_user_id: 1)
      expect(err).to eq(:not_found)
    end

    it 'returns :expired for expired token' do
      expired_tok = create(:tg_link_token, :expired, user: user)
      _, err = described_class.consume!(raw_token: expired_tok.token, tg_user_id: 1)
      expect(err).to eq(:expired)
    end

    it 'returns :already_consumed for re-claim' do
      described_class.consume!(raw_token: tok.token, tg_user_id: 12_345)
      _, err = described_class.consume!(raw_token: tok.token, tg_user_id: 12_345)
      expect(err).to eq(:already_consumed)
    end

    it 'returns :user_already_linked when user has different tg_user_id' do
      user.update_columns(tg_user_id: 99_999, tg_linked_at: 1.day.ago)
      _, err = described_class.consume!(raw_token: tok.token, tg_user_id: 12_345)
      expect(err).to eq(:user_already_linked)
    end

    it 'allows re-link if same tg_user_id (idempotent)' do
      user.update_columns(tg_user_id: 12_345, tg_linked_at: 1.day.ago)
      linked_user, err = described_class.consume!(raw_token: tok.token, tg_user_id: 12_345)
      expect(err).to be_nil
      expect(linked_user).to eq(user)
    end

    it 'returns :tg_user_already_linked_to_other when tg_user_id taken' do
      other = create(:user, :tg_linked, tg_user_id: 12_345)
      _, err = described_class.consume!(raw_token: tok.token, tg_user_id: 12_345)
      expect(err).to eq(:tg_user_already_linked_to_other)
      expect(other.reload.tg_user_id).to eq(12_345) # untouched
    end
  end

  describe 'predicates' do
    let(:user) { create(:user) }

    it '#consumed? reflects consumed_at presence' do
      tok = create(:tg_link_token, user: user)
      expect(tok).not_to be_consumed
      tok.update!(consumed_at: Time.current)
      expect(tok).to be_consumed
    end

    it '#expired? reflects expires_at past' do
      tok = create(:tg_link_token, :expired, user: user)
      expect(tok).to be_expired
    end
  end
end
