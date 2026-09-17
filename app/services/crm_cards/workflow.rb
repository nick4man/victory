# frozen_string_literal: true

module CrmCards
  # Все переходы карточки CRM — только здесь. Мастера, кнопки и команды
  # вызывают эти методы и статус сами не трогают: права из CRM, допустимость
  # перехода и журнал проверяются в одном месте.
  #
  # Методы возвращают Result, а не бросают: отказ по правам — штатный ответ
  # сотруднику, а не авария. Уведомления уходят после снятия блокировки
  # строки, чтобы медленный Telegram не держал её.
  class Workflow
    Result = Struct.new(:ok, :card, :error, keyword_init: true) do
      def ok?
        ok == true
      end
    end

    def initialize(notifier: nil, exporter: nil)
      @notifier = notifier
      @exporter = exporter
    end

    def upsert_lead_card!(lead:, actor:, values:)
      perms = Permissions.for(actor)
      return deny(perms.denial) if perms.denial
      return deny('Твоей должности в CRM не выдано право заводить заявки.') unless perms.can?(:create_lead)

      card = CrmCard.kind_lead.find_or_initialize_by(lead_event_id: lead.id)
      save_values(card, values, actor: actor, perms: perms)
    rescue ActiveRecord::RecordNotUnique
      deny('Карточку по этому лиду только что создал другой сотрудник — открой её кнопкой ещё раз.')
    end

    def create_object_card!(actor:, values:)
      perms = Permissions.for(actor)
      return deny(perms.denial) if perms.denial
      return deny('Твоей должности в CRM не выдано право заводить объекты.') unless perms.can?(:create_object)

      save_values(CrmCard.new(kind: 'object'), values, actor: actor, perms: perms)
    end

    def update_fields!(card, values, actor:)
      save_values(card, values, actor: actor, perms: Permissions.for(actor))
    end

    def submit!(card, actor:)
      moderators = []
      result = card.with_lock do
        perms = Permissions.for(actor)
        card.author = actor if taking_over?(card, actor)
        next deny(edit_denial(card, perms)) unless CrmCard::AUTHOR_EDITABLE.include?(card.status) && can_edit?(card, actor, perms)

        refresh_check(card)
        unless card.check_passed?
          card.save!
          next deny("Машинная проверка не пройдена: #{card.check_errors.size} замеч. — поправь поля и отправь снова.")
        end

        moderators = Permissions.moderators
        next deny('Модераторов с доступом к CRM нет — карточку некому проверить. Сообщи директору.') if moderators.empty?

        transition!(card, to: 'pending_review', actor: actor)
        card.update!(submitted_at: Time.current)
        ok(card)
      end
      notifier.submitted(card, moderators: moderators) if result.ok?
      result
    end

    def return_for_rework!(card, actor:, comment:)
      text = comment.to_s.strip
      result = card.with_lock do
        next deny(moderator_denial(actor, 'Возвращать на доработку')) unless moderator?(actor)
        next deny(not_pending(card)) unless card.status_pending_review?
        next deny('Нужен комментарий: что доработать.') if text.empty?

        transition!(card, to: 'needs_rework', actor: actor, comment: text)
        card.update!(reviewer: actor, reviewed_at: Time.current)
        ok(card)
      end
      notifier.returned(card, comment: text) if result.ok?
      result
    end

    def approve!(card, actor:)
      result = card.with_lock do
        next deny(moderator_denial(actor, 'Одобрять')) unless moderator?(actor)
        next deny(not_pending(card)) unless card.status_pending_review?

        # Модератор мог поправить поля, а лид — закрыться, пока карточка ждала.
        refresh_check(card)
        unless card.check_passed?
          card.save!
          next deny("Машинная проверка больше не проходит: #{card.check_errors.size} замеч. — " \
                    'поправь поля или верни на доработку.')
        end

        transition!(card, to: 'approved', actor: actor)
        card.update!(reviewer: actor, reviewed_at: Time.current, export_mode: card.kind_lead? ? 'api' : 'manual')
        ok(card)
      end
      if result.ok?
        ExportJob.perform_later(card.id) if card.kind_lead?
        notifier.approved(card)
      end
      result
    end

    # Только для ExportJob. Захват approved → exporting атомарный: двойной
    # запуск джоба (ретрай Sidekiq, два процесса) не заведёт две заявки.
    def export!(card)
      claimed = CrmCard.where(id: card.id, kind: 'lead', status: 'approved')
                       .update_all(status: 'exporting', updated_at: Time.current)
      return deny('Карточка не ждёт выгрузки: не одобрена или её уже выгружает другой процесс.') unless claimed == 1

      card.reload
      card.transitions.create!(from_status: 'approved', to_status: 'exporting')
      begin
        outcome = exporter.call(card)
      rescue StandardError => e
        return fail_export!(card, error: "#{e.class}: #{e.message}")
      end

      # Заявка в CRM уже создана — номер фиксируем раньше всего, чтобы сбой
      # ниже не потерял его, а повтор не завёл вторую заявку.
      card.update_columns(crm_id: outcome.crm_id.to_s)
      finalize_export!(card, outcome)
    end

    # mode 'api' — из export!; 'manual' — сотрудник внёс объект руками и ввёл номер.
    def record_export!(card, crm_id:, mode:, actor: nil, warning: nil)
      digits = crm_id.to_s.strip
      result = card.with_lock do
        next deny('Номер карточки в CRM — только цифры.') unless digits.match?(/\A\d{1,12}\z/)

        if mode == 'manual'
          perms = Permissions.for(actor)
          allowed = perms.denial.nil? && (card.responsible&.id == actor.id || perms.can?(:moderate))
          next deny(perms.denial || 'Отметить внесение в CRM может автор карточки или модератор.') unless allowed
          next deny("Карточка не ждёт ручного внесения (#{label(card)}).") unless card.kind_object? && card.status_approved?
        else
          next deny("Карточка не выгружается (#{label(card)}).") unless card.status_exporting?
        end

        transition!(card, to: 'exported', actor: actor, comment: warning)
        card.update!(crm_id: digits, exported_at: Time.current, export_error: warning)
        sync_lead_ref!(card)
        ok(card)
      end
      notifier.exported(card, warning: warning) if result.ok?
      result
    end

    def retry_export!(card, actor:)
      result = card.with_lock do
        next deny(moderator_denial(actor, 'Повторять выгрузку')) unless moderator?(actor)
        next deny('Повтор есть только у заявок — объект вносится в CRM вручную.') unless card.kind_lead?
        next deny("Повторять нечего (#{label(card)}).") unless card.status_export_failed? || card.export_stale?
        next deny("Заявка уже есть в CRM (#{card.crm_id}) — повтор завёл бы вторую. Статус правится вручную.") if card.crm_id.present?

        transition!(card, to: 'approved', actor: actor, comment: 'повтор выгрузки')
        card.update!(export_error: nil)
        ok(card)
      end
      ExportJob.perform_later(card.id) if result.ok?
      result
    end

    def can_edit?(card, actor, perms = Permissions.for(actor))
      return false if perms.denial
      return perms.can?(:moderate) if card.status_pending_review?
      return false unless CrmCard::AUTHOR_EDITABLE.include?(card.status)
      return true if perms.can?(:moderate)

      perms.can?("create_#{card.kind}") && (card.new_record? || card.responsible&.id == actor.id)
    end

    def edit_denial(card, perms)
      return perms.denial if perms.denial
      return 'Карточка на модерации — править её сейчас может только модератор.' if card.status_pending_review?
      return "Карточка уже в статусе «#{label(card)}» — править нечего." unless CrmCard::AUTHOR_EDITABLE.include?(card.status)
      return "Твоей должности в CRM не выдано право заводить #{card.kind_lead? ? 'заявки' : 'объекты'}." unless perms.can?("create_#{card.kind}")

      "Карточку ведёт #{card.responsible.mention}."
    end

    private

    # Автор назначается внутри блокировки: with_lock перечитывает строку и
    # стёр бы несохранённое присваивание.
    def save_values(card, values, actor:, perms:)
      apply = lambda do
        card.author = actor if card.new_record? || taking_over?(card, actor)
        next deny(edit_denial(card, perms)) unless can_edit?(card, actor, perms)

        allowed = Schema.for(card.kind).map(&:key)
        card.payload = card.payload.to_h.merge(values.to_h.stringify_keys.slice(*allowed)).compact
        refresh_check(card)
        card.save!
        ok(card)
      end
      card.persisted? ? card.with_lock(&apply) : apply.call
    end

    # Новый ответственный по лиду перенимает черновик заявки: автором в
    # журнале становится тот, кто её действительно дорабатывал и отправил.
    def taking_over?(card, actor)
      card.kind_lead? && card.lead_event&.assigned_to_id == actor.id && CrmCard::AUTHOR_EDITABLE.include?(card.status)
    end

    def refresh_check(card)
      card.check_errors = Checker.call(card)
      card.checked_at = Time.current
    end

    def transition!(card, to:, actor:, comment: nil)
      from = card.status
      card.update!(status: to)
      card.transitions.create!(from_status: from, to_status: to, actor: actor, comment: comment)
    end

    # Лид с сайта теперь «в CRM»: LeadAssignment#push_to_crm и SpamCallback
    # начинают работать с ним так же, как с пришедшим из CRM.
    def sync_lead_ref!(card)
      ref = card.lead_event&.lead_ref
      return unless ref&.has_attribute?(:crm_id) && ref.crm_id.blank?

      attrs = { crm_id: card.crm_id }
      attrs[:synced_to_crm_at] = Time.current if ref.has_attribute?(:synced_to_crm_at)
      ref.update_columns(attrs) # без колбэков: Inquiry на сохранении шлёт уведомления
    end

    def moderator?(actor)
      Permissions.for(actor).can?(:moderate)
    end

    def moderator_denial(actor, action)
      Permissions.for(actor).denial || "#{action} может только модератор."
    end

    def not_pending(card)
      "Карточка не на модерации (#{label(card)})."
    end

    def label(card)
      CrmCard::STATUS_LABELS[card.status]
    end

    def ok(card)
      Result.new(ok: true, card: card)
    end

    def deny(error)
      Result.new(ok: false, error: error)
    end

    def fail_export!(card, error:)
      message = error.to_s.truncate(500)
      result = card.with_lock do
        next deny('Карточка не выгружается.') unless card.status_exporting?

        transition!(card, to: 'export_failed', actor: nil, comment: message)
        card.update!(export_error: message)
        ok(card)
      end
      notifier.export_failed(card) if result.ok?
      result
    end

    # record_export! может отказать (неверный формат номера) или упасть
    # (БД) уже после того, как CRM приняла заявку — crm_id к этому моменту
    # уже сохранён в export!, остаётся только не потерять карточку молча.
    def finalize_export!(card, outcome)
      result = record_export!(card, crm_id: outcome.crm_id, mode: 'api', warning: outcome.warning)
      result.ok? ? result : lost_export_status!(card, outcome, result.error)
    rescue StandardError => e
      lost_export_status!(card, outcome, "#{e.class}: #{e.message}")
    end

    def lost_export_status!(card, outcome, reason)
      Rails.logger.error("[CrmCards::Workflow] card=#{card.id} создана в CRM #{outcome.crm_id}, но статус не записан: #{reason}")
      fail_export!(card, error: "Заявка уже создана в CRM под номером #{outcome.crm_id}, но статус не записан (#{reason}). " \
                              'Не повторяй выгрузку — поправь статус вручную.')
    end

    def notifier
      @notifier ||= Notifier.new
    end

    def exporter
      @exporter ||= LeadExporter.new
    end
  end
end
