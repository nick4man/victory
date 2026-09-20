# frozen_string_literal: true

module CrmCards
  # Правка поля опубликованной карточки — через модерацию.
  #
  # Само поле в CRM мы пока не патчим: у публичного API нет описанного пути
  # править клиента уже созданной заявки, а угадывать имена полей — значит
  # писать мусор в боевую базу. Поэтому после одобрения карточка обновляется у
  # нас, в CRM уходит заметка с тем, что и на что поменяли, а ответственному
  # приходит просьба поправить поле в CRM руками. Как только путь в API будет
  # подтверждён, замена руками уйдёт отсюда одним местом.
  class ChangeRequests
    Result = Struct.new(:ok, :request, :error, keyword_init: true) do
      def ok? = ok == true
    end

    def initialize(notifier: nil)
      @notifier = notifier
    end

    # @return [Result]
    def open!(card, actor:, field:, value:)
      perms = Permissions.for(actor)
      return deny(perms.denial) if perms.denial
      return deny('Заявку на правку заводит тот, кто ведёт клиента.') unless participant?(card, actor, perms)
      return deny("Карточка ещё не в CRM (#{CrmCard::STATUS_LABELS[card.status]}) — поле правится обычным путём.") unless
        card.status_exported?

      schema_field = Schema.field(card.kind, field)
      return deny('Такого поля в карточке нет.') unless schema_field
      return deny('Значение не изменилось.') if card.payload[field] == value

      request = CrmCardChangeRequest.create!(crm_card: card, author: actor, field: field,
                                             old_value: card.payload[field], new_value: value)
      notifier&.change_requested(request, moderators: Permissions.moderators)
      Result.new(ok: true, request: request)
    rescue ActiveRecord::RecordNotUnique
      deny('По этому полю уже есть заявка на модерации — дождись решения.')
    end

    # @return [Result]
    def approve!(request, actor:)
      decide!(request, actor: actor, to: 'approved') do |req|
        card = req.crm_card
        card.update!(payload: card.payload.merge(req.field => req.new_value))
        Notes.add!(card, actor: actor, text: change_note(req))
      end
    end

    # @return [Result]
    def reject!(request, actor:, comment:)
      text = comment.to_s.strip
      return deny('Нужен комментарий: почему отклонили.') if text.empty?

      decide!(request, actor: actor, to: 'rejected', comment: text)
    end

    private

    attr_reader :notifier

    def deny(error) = Result.new(ok: false, error: error)

    def decide!(request, actor:, to:, comment: nil)
      perms = Permissions.for(actor)
      return deny(perms.denial) if perms.denial
      return deny('Решение по заявке на правку принимает модератор.') unless perms.can?(:moderate)
      return deny('По этой заявке решение уже принято.') unless request.status_pending?

      request.with_lock do
        request.update!(status: to, reviewer: actor, reviewed_at: Time.current, comment: comment)
        yield(request) if block_given?
      end
      notifier&.change_decided(request)
      Result.new(ok: true, request: request)
    end

    def participant?(card, actor, perms)
      card.responsible&.id == actor.id || perms.can?(:moderate)
    end

    # Заметка уходит в CRM: пока поле там правят руками, запись объясняет,
    # что именно изменилось и кто это согласовал.
    def change_note(request)
      label = Schema.field(request.crm_card.kind, request.field)&.label || request.field
      "Согласована правка: «#{label}» — было «#{request.old_value}», стало «#{request.new_value}». " \
        "Одобрил #{request.reviewer&.mention}. Поправьте поле в CRM."
    end
  end
end
