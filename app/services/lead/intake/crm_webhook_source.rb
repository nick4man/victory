# frozen_string_literal: true

module Lead
  class Intake
    # Адаптер «новый order создан в Topnlab» (агент завёл руками либо приехал из колл-центра).
    # Webhooks::TopnlabController после import_property/order вызывает Intake с этим source.
    # Реализуется в Phase 4.
    class CrmWebhookSource
      def call(_payload)
        raise NotImplementedError, 'Lead::Intake::CrmWebhookSource is scheduled for Phase 4'
      end
    end
  end
end
