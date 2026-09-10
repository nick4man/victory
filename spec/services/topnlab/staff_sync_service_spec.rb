# frozen_string_literal: true

require 'rails_helper'

# Регресс на прод-инцидент 08.09.26: TopnlabStaffSyncJob падал ежедневно, все
# 4 ретрая. Причина — вложенный rescue в save_user_safely. Повторный save после
# конфликта по phone спотыкался о index_users_on_crm_user_id, а соседний
# `rescue StandardError` исключение, поднятое ВНУТРИ другого rescue-блока, не
# перехватывает. Оно улетало наружу и роняло весь upsert_users — из 14
# сотрудников часть не синхронизировалась вовсе.
#
# Инвариант, который здесь закреплён: сбой на ОДНОЙ записи не имеет права
# останавливать проход по остальным.
RSpec.describe Topnlab::StaffSyncService do
  subject(:service) { described_class.new(client: client) }

  let(:client) { instance_double(Topnlab::Client) }

  # Минимальная запись сотрудника в формате Topnlab get-users.
  def crm_user(email:, crm_id:, phone: nil, status: 0)
    {
      'email'      => email,
      'id'         => crm_id,
      'firstname'  => 'Иван',
      'lastname'   => 'Петров',
      'fathername' => nil,
      'phone_num'  => phone,
      'role'       => 3,
      'role_name'  => 'Агент',
      'status'     => status
    }
  end

  before do
    # Структуру отделов здесь не проверяем — весь фокус на upsert_users.
    allow(client).to receive(:get_structure).and_return(nil)
  end

  describe 'обычное сохранение' do
    before do
      allow(client).to receive(:get_users).and_return(
        [crm_user(email: 'agent@victory62.test', crm_id: 501, phone: '+79001112233')]
      )
    end

    it 'заводит пользователя и отдаёт его в сводке' do
      result = service.call

      expect(result).to include(success: true, users: 1, skipped_users: 0)
    end

    it 'кладёт в запись данные из CRM' do
      service.call

      user = User.find_by(email: 'agent@victory62.test')
      expect(user).to have_attributes(
        crm_user_id: 501,
        crm_role_name: 'Агент',
        crm_status: 'active',
        phone: '+79001112233'
      )
    end
  end

  describe 'конфликт по phone' do
    # Городской номер в Topnlab делят несколько сотрудников, а
    # index_users_on_phone — UNIQUE без частичного условия.
    #
    # update_column, а не create(phone:): User#normalize_phone (before_validation)
    # срезал бы «+», а синк пишет через save(validate: false) и callback не
    # вызывает — в проде в колонке лежит именно «+7…». Столкнуть номера иначе
    # не получится, форматы просто не совпадут.
    let!(:phone_owner) do
      create(:user).tap { |u| u.update_column(:phone, '+74912555444') }
    end

    before do
      allow(client).to receive(:get_users).and_return(
        [crm_user(email: 'landline@victory62.test', crm_id: 502, phone: '+74912555444')]
      )
    end

    it 'обнуляет телефон и всё-таки сохраняет запись' do
      result = service.call

      expect(result).to include(success: true, users: 1, skipped_users: 0)
      expect(User.find_by(email: 'landline@victory62.test')).to have_attributes(
        phone: nil, crm_user_id: 502
      )
    end

    it 'не трогает телефон у того, кто занял номер первым' do
      service.call

      expect(phone_owner.reload.phone).to eq('+74912555444')
    end
  end

  describe 'конфликт по phone, а затем по crm_user_id на повторном сохранении' do
    # Оба сохранения падают по-настоящему, но какой именно индекс сообщит о себе
    # первым, PostgreSQL решает сам — поэтому последовательность конфликтов
    # задаём явно, иначе спек ловил бы то одну ветку, то другую.
    let(:doomed) { build(:user, email: 'doomed@victory62.test') }

    before do
      allow(client).to receive(:get_users).and_return(
        [
          crm_user(email: 'doomed@victory62.test', crm_id: 503, phone: '+74912555111'),
          crm_user(email: 'next-in-line@victory62.test', crm_id: 504, phone: '+79005556677')
        ]
      )

      allow(User).to receive(:find_or_initialize_by).and_call_original
      allow(User).to receive(:find_or_initialize_by)
        .with(email: 'doomed@victory62.test').and_return(doomed)

      saves = 0
      allow(doomed).to receive(:save) do
        saves += 1
        raise ActiveRecord::RecordNotUnique, unique_violation('index_users_on_phone') if saves == 1

        raise ActiveRecord::RecordNotUnique, unique_violation('index_users_on_crm_user_id')
      end
    end

    def unique_violation(index)
      %(PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint "#{index}")
    end

    it 'не выпускает исключение наружу' do
      expect { service.call }.not_to raise_error
    end

    it 'пропускает запись и считает её в сводке' do
      result = service.call

      expect(result).to include(success: true, users: 1, skipped_users: 1)
    end

    it 'продолжает проход и сохраняет следующего сотрудника' do
      service.call

      expect(User.find_by(email: 'next-in-line@victory62.test')).to be_present
    end

    it 'пишет в лог маску вместо адреса — email это персональные данные' do
      allow(Rails.logger).to receive(:warn)

      service.call

      expect(Rails.logger).to have_received(:warn)
        .with(/\[StaffSync\] skipped d\*\*\*d@victory62\.test/).at_least(:once)
      expect(Rails.logger).not_to have_received(:warn).with(/doomed@/)
    end
  end

  describe 'запись без email' do
    before do
      allow(client).to receive(:get_users).and_return(
        [crm_user(email: '', crm_id: 505), crm_user(email: 'ok@victory62.test', crm_id: 506)]
      )
    end

    it 'считается пропущенной, а не молча исчезает' do
      result = service.call

      expect(result).to include(users: 1, skipped_users: 1)
    end
  end

  describe 'мусор вместо записи в payload' do
    # Topnlab отвечает на get-users то массивом, то хешем-хешей, и клиент
    # разворачивает второй вариант через data.values.flatten — оттуда легко
    # приезжает не-Hash. Раньше `u['email']` на нём поднимал TypeError мимо
    # всех rescue и ронял весь проход.
    before do
      allow(client).to receive(:get_users).and_return(
        [14, crm_user(email: 'survivor@victory62.test', crm_id: 507)]
      )
    end

    it 'не роняет проход и сохраняет нормальную запись' do
      expect { service.call }.not_to raise_error
      expect(User.find_by(email: 'survivor@victory62.test')).to be_present
    end

    it 'считает мусор пропуском' do
      expect(service.call).to include(users: 1, skipped_users: 1)
    end
  end
end
