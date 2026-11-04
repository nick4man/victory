# frozen_string_literal: true

namespace :crm_cards do
  desc 'Права сотрудников на карточки CRM: должность в Topnlab → возможности или причина отказа'
  task permissions: :environment do
    puts CrmCards::PermissionsReport.new.lines
  end
end
