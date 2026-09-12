# frozen_string_literal: true

module Lead
  # BOTTLENECK — единственное место, где лид превращается в объект.
  #
  # lead_ref полиморфный (Inquiry / Property / PropertyValuation / BuyerOrder),
  # и до этого каждый потребитель (LeadStageTransition#resolve_seller_user,
  # TaskBatchConfirmer#nc_link_for) резолвил объект по-своему. Для метрик
  # «по объектам, а не по людям» нужен один ответ на вопрос «какой объект
  # показывали», поэтому логика вынесена сюда, а результат денормализуется в
  # lead_events.property_id (см. миграцию 20260911100000).
  #
  # unscoped — осознанно: объект мог уйти в архив/soft-delete после показа,
  # а история показов по нему должна остаться привязанной.
  class PropertyResolver
    def self.for_ref(ref)
      return nil if ref.nil?
      return ref if ref.is_a?(::Property)
      return nil unless ref.respond_to?(:property_id) && ref.property_id.present?

      ::Property.unscoped.find_by(id: ref.property_id)
    end

    def self.call(lead_event)
      return lead_event.property if lead_event.property_id.present?

      for_ref(lead_event.lead_ref)
    end
  end
end
