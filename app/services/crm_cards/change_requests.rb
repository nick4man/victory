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
        apply_to_card!(req, actor: actor)
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
      return deny(wrong_bot) unless request.crm_card.sandbox? == Telegram::BotContext.test?

      applied = false
      request.with_lock do
        # Проверка статуса — внутри блокировки: два модератора, нажавшие
        # «Принять» одновременно, иначе оба прошли бы мимо неё, и в CRM ушли
        # бы две одинаковые записи о согласовании.
        next unless request.status_pending?

        request.update!(status: to, reviewer: actor, reviewed_at: Time.current, comment: comment)
        yield(request) if block_given?
        applied = true
      end
      return deny('По этой заявке решение уже принято.') unless applied

      # Заметка — после коммита: иначе джоб отправки в CRM успевает стартовать
      # раньше, не находит записи и молча бросает её без повтора.
      note_change(request, actor: actor) if to == 'approved'
      notifier&.change_decided(request)
      Result.new(ok: true, request: request)
    end

    def wrong_bot
      Telegram::BotContext.test? ? 'Это боевая карточка — решение по ней принимают в рабочем боте.' : 'Это карточка песочницы — решение по ней принимают в тестовом боте.'
    end

    # Правка поля — под блокировкой самой карточки: параллельное одобрение
    # правок двух разных полей иначе затирало бы одно другим.
    def apply_to_card!(request, actor:)
      card = request.crm_card
      card.with_lock do
        card.reload
        card.payload = card.payload.merge(request.field => request.new_value).compact
        # Проверку пересчитываем: иначе карточка после правки показывала бы
        # вчерашнее «проверка пройдена» по старым значениям.
        card.check_errors = Checker.call(card)
        card.checked_at = Time.current
        card.save!
        card.transitions.create!(from_status: card.status, to_status: card.status, actor: actor,
                                 comment: "правка поля «#{label_for(request)}» согласована")
      end
    end

    # Заметка — единственный след правки в CRM, пока поле там меняют руками.
    # Не смогли записать — честно говорим автору, а не обещаем несуществующее.
    def note_change(request, actor:)
      result = Notes.add!(request.crm_card, actor: actor, text: change_note(request))
      return if result.ok?

      Rails.logger.warn("[CrmCards::ChangeRequests] заметка по правке ##{request.id} не сохранена: #{result.error}")
      notifier&.change_note_failed(request)
    end

    def participant?(card, actor, perms)
      card.responsible&.id == actor.id || perms.can?(:moderate)
    end

    def label_for(request)
      Schema.field(request.crm_card.kind, request.field)&.label || request.field
    end

    # Значения режем: у объекта комментарий влезает в 1000 символов, и пара
    # таких значений вышла бы за лимит заметки — запись не сохранилась бы вовсе.
    VALUE_IN_NOTE = 200

    # Заметка уходит в CRM: пока поле там правят руками, запись объясняет,
    # что именно изменилось и кто это согласовал.
    def change_note(request)
      field = Schema.field(request.crm_card.kind, request.field)
      was = shown(field, request.old_value)
      now = shown(field, request.new_value)
      "Согласована правка: «#{label_for(request)}» — было «#{was}», стало «#{now}». " \
        "Одобрил #{request.reviewer&.mention}. Поправьте поле в CRM."
    end

    def shown(field, value)
      return '—' if value.nil?

      text = field ? CardView.plain_value(field, value) : value.to_s
      text.to_s.truncate(VALUE_IN_NOTE)
    end
  end
end
