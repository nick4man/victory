# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User, type: :model do
  # ============================================
  # ASSOCIATIONS
  # ============================================
  describe 'associations' do
    it { is_expected.to have_many(:properties).dependent(:destroy) }
    it { is_expected.to have_many(:favorites).dependent(:destroy) }
    it { is_expected.to have_many(:inquiries).dependent(:destroy) }
    it { is_expected.to have_many(:saved_searches).dependent(:destroy) }
  end

  # ============================================
  # VALIDATIONS
  # ============================================
  describe 'validations' do
    subject { build(:user) }

    it { is_expected.to validate_presence_of(:email) }
    it { is_expected.to validate_uniqueness_of(:email).case_insensitive }
  end

  # ============================================
  # ENUMS
  # ============================================
  describe 'enums' do
    it { is_expected.to define_enum_for(:role).with_values(client: 0, agent: 1, admin: 2).with_prefix }
  end

  # ============================================
  # SCOPES
  # ============================================
  describe 'scopes' do
    let!(:active_user)   { create(:user, active: true) }
    let!(:inactive_user) { create(:user, :inactive) }
    let!(:admin_user)    { create(:user, :admin) }
    let!(:agent_user)    { create(:user, :agent) }

    describe '.active' do
      it 'возвращает только активных пользователей' do
        expect(User.active).to include(active_user)
        expect(User.active).not_to include(inactive_user)
      end
    end

    describe '.agents' do
      it 'возвращает только агентов' do
        expect(User.agents).to include(agent_user)
        expect(User.agents).not_to include(active_user)
      end
    end

    describe '.admins' do
      it 'возвращает только администраторов' do
        expect(User.admins).to include(admin_user)
        expect(User.admins).not_to include(agent_user)
      end
    end
  end

  # ============================================
  # INSTANCE METHODS
  # ============================================
  describe '#full_name' do
    it 'возвращает полное имя пользователя' do
      user = build(:user, first_name: 'Иван', last_name: 'Петров')
      expect(user.full_name).to include('Иван')
      expect(user.full_name).to include('Петров')
    end
  end

  describe '#admin?' do
    it 'возвращает true для администратора' do
      expect(build(:user, :admin)).to be_role_admin
    end

    it 'возвращает false для клиента' do
      expect(build(:user, :client)).not_to be_role_admin
    end
  end

  describe '#agent?' do
    it 'возвращает true для агента' do
      expect(build(:user, :agent)).to be_role_agent
    end
  end

  describe '#active?' do
    it 'возвращает true для активного пользователя' do
      expect(build(:user, active: true)).to be_active
    end

    it 'возвращает false для неактивного пользователя' do
      expect(build(:user, :inactive)).not_to be_active
    end
  end

  # ============================================
  # SOFT DELETE
  # ============================================
  describe 'мягкое удаление' do
    let(:user) { create(:user) }

    it 'исключает пользователя с deleted_at из default scope' do
      user.update!(deleted_at: Time.current)
      expect(User.all).not_to include(user)
    end
  end
end
