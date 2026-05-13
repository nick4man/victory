# frozen_string_literal: true

module Lead
  class Intake
    # Адаптер «клиент пишет боту в личку». Будет реализован в Phase 4.
    # Текущая заглушка — чтобы Lead::Intake.adapter_for резолвился.
    class TgDmSource
      def call(_payload)
        raise NotImplementedError, 'Lead::Intake::TgDmSource is scheduled for Phase 4'
      end
    end
  end
end
