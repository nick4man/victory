# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TelegramUser do
  describe 'validations' do
    it 'требует tg_user_id' do
      expect(described_class.new(tg_user_id: nil)).not_to be_valid
    end

    it 'tg_user_id уникален' do
      described_class.create!(tg_user_id: 12_345)
      dup = described_class.new(tg_user_id: 12_345)
      expect(dup).not_to be_valid
      expect(dup.errors[:tg_user_id]).to be_present
    end

    it 'status — только из STATUSES' do
      u = described_class.new(tg_user_id: 1, status: 'wat')
      expect(u).not_to be_valid
    end
  end

  describe '.find_by_username' do
    let!(:user) { described_class.create!(tg_user_id: 1, tg_username: 'IvanPetrov') }

    it 'находит по точному username' do
      expect(described_class.find_by_username('IvanPetrov')).to eq(user)
    end

    it 'не чувствителен к регистру' do
      expect(described_class.find_by_username('ivanpetrov')).to eq(user)
    end

    it 'отрезает @-префикс' do
      expect(described_class.find_by_username('@IvanPetrov')).to eq(user)
    end

    it 'возвращает nil для blank' do
      expect(described_class.find_by_username(nil)).to be_nil
      expect(described_class.find_by_username('')).to be_nil
    end
  end

  describe '.resolve_identifier' do
    let!(:with_uname)    { described_class.create!(tg_user_id: 100, tg_username: 'IvanPetrov', first_name: 'Иван') }
    let!(:without_uname) { described_class.create!(tg_user_id: 200, first_name: 'Надежда') }

    it 'резолвит @username (case-insensitive, с @-префиксом)' do
      expect(described_class.resolve_identifier('@ivanpetrov')).to eq(with_uname)
      expect(described_class.resolve_identifier('IVANPETROV')).to eq(with_uname)
    end

    it 'резолвит id:N формат для staff без tg_username' do
      expect(described_class.resolve_identifier("id:#{without_uname.id}")).to eq(without_uname)
    end

    it 'id-формат case-insensitive по префиксу' do
      expect(described_class.resolve_identifier("ID:#{without_uname.id}")).to eq(without_uname)
    end

    it 'возвращает nil для blank' do
      expect(described_class.resolve_identifier(nil)).to be_nil
      expect(described_class.resolve_identifier('')).to be_nil
      expect(described_class.resolve_identifier('   ')).to be_nil
    end

    it 'возвращает nil для несуществующего username / id' do
      expect(described_class.resolve_identifier('ghost_user')).to be_nil
      expect(described_class.resolve_identifier('id:999999')).to be_nil
    end

    it 'не путает id:14 с литеральным username' do
      # литеральный username "id" сам по себе не может существовать в TG
      # (минимум 5 chars), но проверяем что префикс распознаётся приоритетно
      expect(described_class.resolve_identifier('id:abc')).to be_nil
    end
  end

  describe '#mention' do
    it 'возвращает @username если есть' do
      u = described_class.new(tg_user_id: 1, tg_username: 'ivan')
      expect(u.mention).to eq('@ivan')
    end

    it 'возвращает display_name если нет username' do
      u = described_class.new(tg_user_id: 1, first_name: 'Иван', last_name: 'Петров')
      expect(u.mention).to eq('Иван Петров')
    end

    it 'фоллбэк tg:<id> когда нет ни username ни имени' do
      u = described_class.new(tg_user_id: 999)
      expect(u.mention).to eq('tg:999')
    end
  end

  describe '#linked_to_crm?' do
    it 'true когда есть и topnlab_user_id и email' do
      u = described_class.new(tg_user_id: 1, topnlab_user_id: 7, email: 'a@b.ru')
      expect(u.linked_to_crm?).to be(true)
    end

    it 'false когда чего-то не хватает' do
      expect(described_class.new(tg_user_id: 1, topnlab_user_id: 7).linked_to_crm?).to be(false)
      expect(described_class.new(tg_user_id: 1, email: 'a@b.ru').linked_to_crm?).to be(false)
    end
  end

  # Iter 60 — multi-turn conversation state в DM
  describe '#set_pending_action! / #pending_action / #clear_pending_action!' do
    let(:user) { described_class.create!(tg_user_id: 21_001, first_name: 'Test', status: 'active') }

    it 'set_pending_action! сохраняет type/data/expires_at в jsonb' do
      user.set_pending_action!(type: 'photo_disposition', data: { file_id: 'abc' }, step: 'choose_destination')
      pa = user.reload.dm_pending_action
      expect(pa['type']).to eq('photo_disposition')
      expect(pa['step']).to eq('choose_destination')
      expect(pa['data']['file_id']).to eq('abc')
      expect(pa['expires_at']).to be_present
    end

    it 'pending_action возвращает Hash with indifferent access для active state' do
      user.set_pending_action!(type: :photo_disposition, data: { file_id: 'xyz' })
      pa = user.pending_action
      expect(pa[:type]).to eq('photo_disposition')
      expect(pa['type']).to eq('photo_disposition')
      expect(pa['data']['file_id']).to eq('xyz')
    end

    it 'pending_action возвращает nil и очищает state после TTL' do
      user.set_pending_action!(type: 'photo_disposition', data: {}, ttl: 1.second)
      travel_to(2.seconds.from_now) do
        expect(user.pending_action).to be_nil
        expect(user.reload.dm_pending_action).to eq({})
      end
    end

    it 'clear_pending_action! сбрасывает в пустой hash' do
      user.set_pending_action!(type: 'x', data: {})
      user.clear_pending_action!
      expect(user.reload.dm_pending_action).to eq({})
    end

    it 'pending_action возвращает nil при пустом state' do
      expect(user.pending_action).to be_nil
    end
  end
end
