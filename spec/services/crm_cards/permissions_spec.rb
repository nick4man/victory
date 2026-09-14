# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Permissions do
  before { stub_crm_positions }

  it 'агент получает возможности своей должности в CRM' do
    perms = described_class.for(crm_staff(tg_user_id: 98_101))

    expect(perms.can?(:create_lead)).to be(true)
    expect(perms.can?(:create_object)).to be(true)
    expect(perms.can?(:moderate)).to be(false)
    expect(perms.position_title).to eq('Агент')
    expect(perms.denial).to be_nil
  end

  it 'роль в боте прав не даёт: директор бота с должностью «Конструктор» не модерирует' do
    perms = described_class.for(crm_staff(tg_user_id: 98_102, position: '1', role: 'director'))

    expect(perms.can?(:moderate)).to be(false)
    expect(perms.denial).to include('«Конструктор»', 'не выданы права')
  end

  it 'заблокированный в CRM теряет все права' do
    perms = described_class.for(crm_staff(tg_user_id: 98_103, crm_status: 'blocked'))

    expect(perms.can?(:create_lead)).to be(false)
    expect(perms.denial).to include('blocked')
  end

  it 'без привязки к CRM — подсказка про /whoami' do
    staff = TelegramUser.create!(tg_user_id: 98_104, status: 'active')

    expect(described_class.for(staff).denial).to include('/whoami')
  end

  it 'учётки нет в справочнике сотрудников — объяснение про ночную синхронизацию' do
    staff = TelegramUser.create!(tg_user_id: 98_105, status: 'active', topnlab_user_id: 123_456)

    expect(described_class.for(staff).denial).to include('ночью')
  end

  it 'две разные учётки CRM на одном телеграме — отказ, а не выбор наугад' do
    staff = crm_staff(tg_user_id: 98_106)
    create(:user, role: :agent, crm_user_id: 999_001, crm_role_id: '90328', crm_role_name: 'Юрист',
                  crm_status: 'blocked', telegram_user: staff)

    expect(described_class.for(staff).denial).to include('двум разным учёткам')
  end

  it 'неактивный в боте — без прав' do
    staff = crm_staff(tg_user_id: 98_107)
    staff.update!(status: 'inactive')

    expect(described_class.for(staff).can?(:create_lead)).to be(false)
  end

  it 'moderators — активные сотрудники с правом moderate' do
    boss = crm_staff(tg_user_id: 98_108, position: '89884')
    crm_staff(tg_user_id: 98_109)

    expect(described_class.moderators).to eq([boss])
  end

  it 'настоящая таблица читается и называет только известные возможности' do
    allow(described_class).to receive(:positions).and_call_original

    expect(described_class.positions).not_to be_empty
    described_class.positions.each_value do |position|
      expect(position['capabilities'] - described_class::CAPABILITIES).to be_empty
    end
  end
end
