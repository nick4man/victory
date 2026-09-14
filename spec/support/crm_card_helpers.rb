# frozen_string_literal: true

# Сотрудник с должностью в CRM — для спек карточек CRM. Права берутся из
# таблицы должностей, поэтому спеки подставляют свою и не зависят от
# содержимого config/crm_permissions.yml, которое правит руководитель.
module CrmCardHelpers
  CRM_TEST_POSITIONS = {
    '89884' => { 'title' => 'Генеральный директор', 'capabilities' => %w[create_lead create_object moderate] },
    '89879' => { 'title' => 'Агент', 'capabilities' => %w[create_lead create_object] },
    '89878' => { 'title' => 'Стажер', 'capabilities' => %w[create_lead] }
  }.freeze

  def stub_crm_positions(positions = CRM_TEST_POSITIONS)
    allow(CrmCards::Permissions).to receive(:positions).and_return(positions)
  end

  # @return [TelegramUser]
  def crm_staff(tg_user_id:, position: '89879', crm_status: 'active', role: 'agent', username: nil)
    crm_user_id = 700_000 + tg_user_id
    staff = TelegramUser.create!(tg_user_id: tg_user_id, tg_username: username, first_name: username || 'Сотрудник',
                                 role: role, status: 'active', dm_chat_id: tg_user_id,
                                 topnlab_user_id: crm_user_id, email: "staff#{tg_user_id}@victory.test")
    FactoryBot.create(:user, role: :agent, crm_user_id: crm_user_id, crm_role_id: position,
                             crm_role_name: CRM_TEST_POSITIONS.dig(position, 'title') || 'Конструктор',
                             crm_status: crm_status)
    staff
  end
end

RSpec.configure { |config| config.include CrmCardHelpers }
