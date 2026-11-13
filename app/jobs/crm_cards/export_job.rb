# frozen_string_literal: true

module CrmCards
  # Выгрузка одобренной заявки в CRM. Вся логика — в Workflow#export!.
  class ExportJob < ApplicationJob
    queue_as :default

    # Исключения не пробрасываются намеренно: ApplicationJob объявляет
    # retry_on StandardError, а Topnlab не идемпотентна — повторный
    # importClient после таймаута заводит вторую заявку. Карточка останется
    # «выгружается»; через 15 минут модератор увидит кнопку «Номер из CRM» —
    # recovery только через attach_export_number! после сверки с CRM
    # (ревью PR #210, round 7).
    def perform(card_id)
      card = CrmCard.find_by(id: card_id)
      return unless card

      Workflow.new.export!(card)
    rescue StandardError => e
      Rails.logger.error("[CrmCards::ExportJob] card=#{card_id} #{e.class}: #{e.message}")
    end
  end
end
