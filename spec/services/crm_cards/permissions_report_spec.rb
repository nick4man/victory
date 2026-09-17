# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::PermissionsReport do
  before { stub_crm_positions }

  it 'по каждому активному сотруднику — роль в боте, должность в CRM и итог' do
    crm_staff(tg_user_id: 98_201, username: 'irina')
    crm_staff(tg_user_id: 98_202, username: 'sergey', position: '1', role: 'director')

    text = described_class.new.lines.join("\n")

    expect(text).to include('@irina · бот: agent · CRM: Агент → create_lead, create_object')
    expect(text).to include('@sergey · бот: director · CRM: Конструктор → нет прав:')
    expect(text).to include('Модераторов нет')
  end

  it 'перечисляет модераторов' do
    crm_staff(tg_user_id: 98_203, username: 'oksana', position: '89884', role: 'director')

    expect(described_class.new.lines).to include('Модераторы: @oksana')
  end

  it 'предупреждает, если должность переименовали в CRM' do
    staff = crm_staff(tg_user_id: 98_204, username: 'irina')
    User.find_by(crm_user_id: staff.topnlab_user_id).update_columns(crm_role_name: 'Агент по продажам')

    expect(described_class.new.lines.join("\n"))
      .to include('Должность 89879: в CRM «Агент по продажам», в config/crm_permissions.yml «Агент»')
  end

  it 'без телефонов и email' do
    crm_staff(tg_user_id: 98_205, username: 'irina')

    expect(described_class.new.lines.join("\n")).not_to include('@victory.test')
  end
end
