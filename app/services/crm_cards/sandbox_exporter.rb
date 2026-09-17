# frozen_string_literal: true

module CrmCards
  # Выгрузка в песочнице тестового бота: в Topnlab ничего не пишется.
  # Номер «TEST-<id>» не спутать с настоящим ни в карточке, ни в журнале.
  class SandboxExporter
    def call(card)
      LeadExporter::Outcome.new(crm_id: "TEST-#{card.id}", warning: 'песочница: в CRM ничего не записано')
    end
  end
end
