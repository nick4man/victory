# frozen_string_literal: true

module CrmCards
  # Одобренная заявка → CRM через публичный API. Единственный вызов
  # import_client в приложении (single_write_path_spec).
  #
  # Ответственный в CRM — тот, кто отвечает за карточку сейчас
  # (CrmCard#responsible): лид могли переназначить между отправкой на
  # модерацию и одобрением, и заявка обязана уйти к новому ответственному.
  class LeadExporter
    Outcome = Struct.new(:crm_id, :warning, keyword_init: true)

    def initialize(topnlab: nil)
      @topnlab = topnlab
    end

    # @return [Outcome]
    # @raise [Topnlab::Client::Error] заявка не создана
    def call(card)
      values = card.payload
      response = topnlab.import_client(
        phone: values['phone'], name: values['name'], source: card.lead_event&.source.to_s,
        realty_id: values['realty_id'], comment: values['comment'],
        action: values['action'] == 'rent' ? 0 : 1, object_type: values['object_type']
      )
      crm_id = response['insertedId'].to_s
      raise Topnlab::Client::Error, 'importClient ответил ok без insertedId' if crm_id.blank?

      Outcome.new(crm_id: crm_id, warning: assign_responsible(crm_id, card.responsible))
    end

    private

    # Клиент Topnlab кидает на отсутствии ENV — создаём его только при
    # выгрузке, а не при построении Workflow в каждом мастере.
    def topnlab
      @topnlab ||= Topnlab::Client.new
    end

    # Заявка уже создана: сбой назначения выгрузку не отменяет, а
    # возвращается предупреждением — ответственного поставят в CRM руками.
    # Ловим любую ошибку, не только Topnlab::Client::Error: сырой сетевой сбой
    # (ECONNREFUSED, SSL) иначе вылетел бы до Outcome, номер заявки потерялся
    # бы, и повтор выгрузки завёл бы в CRM вторую заявку.
    def assign_responsible(crm_id, author)
      return "у #{author.mention} нет email в привязке к CRM — ответственный не назначен" if author.email.blank?

      topnlab.transfer_client(order_id: crm_id.to_i, email: author.email)
      nil
    rescue StandardError => e
      "ответственный не назначен: #{e.class}: #{e.message.truncate(160)}"
    end
  end
end
