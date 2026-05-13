# frozen_string_literal: true

module Lead
  class Intake
    # Адаптер для команды `/lead +7900XXX ЖК Северный, бюджет 8 млн` в чате.
    # Реализуется в Phase 2 (когда появятся командные хендлеры WorkBot).
    class ManualSource
      def call(_payload)
        raise NotImplementedError, 'Lead::Intake::ManualSource is scheduled for Phase 2'
      end
    end
  end
end
