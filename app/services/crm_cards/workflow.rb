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
      sandbox_lead = Checker.sandbox_lead?(lead)
      if Telegram::BotContext.test? && !sandbox_lead
        return deny('В тестовом боте карточки заводятся только по тестовым лидам.')
      end
      return deny('Это тестовый лид песочницы — его карточку заводят в тестовом боте.') if !Telegram::BotContext.test? && sandbox_lead

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
        next deny(wrong_bot(card)) if wrong_bot(card)
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
        next deny(wrong_bot(card)) if wrong_bot(card)
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
    # Токен попытки ставится тем же update_all: проснувшаяся stale-попытка
    # ничего не перезапишет. Advisory lock здесь сериализует только вход
    # джоба; повтор из 'exporting' (свежего или stale) в retry_export!
    # запрещён безусловно — по свободному lockу живость HTTP-вызова не
    # доказать — и восстанавливается только ручной сверкой с CRM (ревью
    # PR #210).
    def export!(card)
      unless ExportLock.try_acquire(card)
        Rails.logger.warn("[CrmCards::Workflow] card=#{card.id} выгрузку уже ведёт другой процесс — job пропущен")
        return deny('Карточку уже выгружает другой процесс — повтор запустится после его завершения.')
      end

      begin
        export_with_lock(card)
      ensure
        ExportLock.release(card)
      end
    end

    # Тело export! под advisory lock; сам lock держится в export!.
    def export_with_lock(card)
      token = SecureRandom.hex(8)
      claimed = CrmCard.where(id: card.id, kind: 'lead', status: 'approved')
                       .update_all(status: 'exporting', export_attempt_token: token, updated_at: Time.current)
      return deny('Карточка не ждёт выгрузки: не одобрена или её уже выгружает другой процесс.') unless claimed == 1

      card.reload
      card.transitions.create!(from_status: 'approved', to_status: 'exporting')
      begin
        outcome = (card.sandbox? ? SandboxExporter.new : exporter).call(card)
      rescue StandardError => e
        # Явный отказ CRM/ошибка до отправки (Error: 403, 4xx, status:error,
        # OpenTimeout) — заявка точно не создана, повтор безопасен.
        # AmbiguousError (ReadTimeout, обрыв после отправки, 5xx, битое тело,
        # ok без insertedId) — CRM могла принять заявку, повтор без сверки
        # завёл бы дубль: восстановление только через привязку номера из CRM
        # (ревью PR #210, round 7).
        return fail_export!(card, error: "#{e.class}: #{e.message}", attempt_token: token,
                            retryable: e.is_a?(Topnlab::Client::Error) &&
                                       !e.is_a?(Topnlab::Client::AmbiguousError))
      end

      # Запись номера — условная по токену и атомарная: retry мог сменить
      # токен между любой отдельной проверкой и записью, а update_all либо
      # пишет по живому токену, либо трогает ноль строк.
      begin
        written = CrmCard.where(id: card.id, export_attempt_token: token)
                         .update_all(crm_id: outcome.crm_id.to_s)
      rescue StandardError => e
        # База недоступна — номер остаётся только в логе; без этой строки
        # карточка через 15 минут предложит повтор, и он заведёт дубль.
        Rails.logger.error("[CrmCards::Workflow] заявка создана в CRM под номером #{outcome.crm_id}, " \
                           "но номер не записан в карточку ##{card.id}: #{e.class}: #{e.message}")
        raise
      end
      unless written == 1
        Rails.logger.warn("[CrmCards::Workflow] card=#{card.id} попытка выгрузки устарела " \
                          '(токен сменился до записи номера) — результат игнорируем')
        return deny('Выгрузка устарела: карточку уже обрабатывает другая попытка.')
      end

      finalize_export!(card.reload, outcome, attempt_token: token)
    end

    # mode 'api' — из export!; 'manual' — сотрудник внёс объект руками и ввёл номер.
    def record_export!(card, crm_id:, mode:, actor: nil, warning: nil, attempt_token: nil)
      digits = crm_id.to_s.strip
      result = card.with_lock do
        number = card.sandbox? ? /\A(TEST-)?\d{1,12}\z/ : /\A\d{1,12}\z/
        next deny('Номер карточки в CRM — только цифры.') unless digits.match?(number)

        if mode == 'manual'
          perms = Permissions.for(actor)
          allowed = perms.denial.nil? && (card.responsible&.id == actor.id || perms.can?(:moderate))
          next deny(perms.denial || 'Отметить внесение в CRM может автор карточки или модератор.') unless allowed
          next deny("Карточка не ждёт ручного внесения (#{label(card)}).") unless card.kind_object? && card.status_approved?
        else
          next deny("Карточка не выгружается (#{label(card)}).") unless card.status_exporting?
          # Чужая (stale) попытка не финализирует чужую выгрузку: токен
          # совпадает только у попытки, захватившей статус последней.
          next deny('Чужая попытка выгрузки — результат не записываем.') if attempt_token && !attempt_current?(card, attempt_token)
        end

        transition!(card, to: 'exported', actor: actor, comment: warning)
        card.update!(crm_id: digits, exported_at: Time.current, export_error: warning)
        sync_lead_ref!(card)
        ok(card)
      end
      notifier.exported(card, warning: warning) if result.ok?
      result
    rescue ActiveRecord::RecordNotUnique => e
      raise unless e.message.include?('idx_crm_cards_unique_exported_object_crm_id')

      deny("Номер #{digits} уже отмечен у другого объекта — проверь цифры в адресе карточки Topnlab.")
    end

    # Автоматический повтор выгрузки — только из детерминированного отказа
    # (export_failed с export_retryable == true): запрос дошёл до CRM и был
    # явно отклонён, вторая заявка невозможна. Из неоднозначного исхода
    # (stale 'exporting', AmbiguousError, ok без insertedId) новый importClient
    # запрещён безусловно: сверка модератора глазами не отменяет уже
    # выполненную CRM-заявку — окно между сверкой и повтором открыто
    # (ревью PR #210, round 7). Там восстановление — attach_export_number!:
    # модератор находит заявку в CRM по телефону (или вносит её руками)
    # и привязывает номер, новый importClient не вызывается.
    def retry_export!(card, actor:)
      result = card.with_lock do
        next deny(wrong_bot(card)) if wrong_bot(card)
        next deny(moderator_denial(actor, 'Повторять выгрузку')) unless moderator?(actor)
        next deny('Повтор есть только у заявок — объект вносится в CRM вручную.') unless card.kind_lead?
        next deny("Заявка уже есть в CRM (#{card.crm_id}) — повтор завёл бы вторую. Статус правится вручную.") if card.crm_id.present?

        if card.status_exporting?
          # 'exporting' — попытка жива или её исход неизвестен (stale):
          # HTTP-вызов с ограниченными таймаутами давно завершился, но CRM
          # могла принять заявку, а ответ потеряться. Повтор — только после
          # сверки с CRM и привязки номера (attach_export_number!).
          next deny('Выгрузка ещё выполняется или её исход неизвестен — повтор запрещён, привяжи номер из CRM после сверки.')
        else
          next deny('Повтор есть только у заявок в статусе «сбой выгрузки» или «одобрена».') unless card.status_export_failed? || card.status_approved?
          if card.status_export_failed? && card.export_retryable == false
            # ReadTimeout/обрыв/5xx/битое тело: CRM могла принять заявку,
            # повтор завёл бы дубль — только сверка и привязка номера (round 7).
            next deny('CRM могла принять заявку, а ответ потеряться. Повтор запрещён — сверь заявку с CRM и привяжи номер кнопкой «Номер из CRM».')
          end
        end

        transition!(card, to: 'approved', actor: actor, comment: 'повтор выгрузки')
        # Токен чистим: живая старая попытка проснётся, увидит nil/чужой
        # токен и ничего не перезапишет (гонка с retry_export!, PR #210).
        card.update!(export_error: nil, export_attempt_token: nil, export_retryable: true)
        ok(card)
      end
      ExportJob.perform_later(card.id) if result.ok?
      result
    end

    # Восстановление из неоднозначного исхода БЕЗ нового importClient:
    # модератор сверил заявку с CRM по телефону (или внёс её в CRM руками)
    # и вводит найденный номер. Токен попытки чистим — если она ещё жива
    # (статус 'exporting'), её проснувшийся результат проигнорируется
    # условной записью по токену и не перезапишет привязанный номер
    # (ревью PR #210, round 7).
    def attach_export_number!(card, crm_id:, actor:)
      digits = crm_id.to_s.strip
      result = card.with_lock do
        next deny(moderator_denial(actor, 'Привязывать номер из CRM')) unless moderator?(actor)
        next deny('Привязка — только у заявок.') unless card.kind_lead?
        next deny('Номер карточки в CRM — только цифры.') unless digits.match?(/\A\d{1,12}\z/)
        unless card.status_export_failed? || card.status_exporting? || card.status_approved?
          next deny("Привязывать нечего (#{label(card)}).")
        end

        transition!(card, to: 'exported', actor: actor, comment: "привязан номер из CRM после сверки: #{digits}")
        card.update!(crm_id: digits, exported_at: Time.current, export_error: nil,
                     export_attempt_token: nil, export_retryable: true)
        sync_lead_ref!(card)
        ok(card)
      end
      notifier.exported(card) if result.ok?
      result
    end

    def can_edit?(card, actor, perms = Permissions.for(actor))
      return false if perms.denial || wrong_bot(card)
      return perms.can?(:moderate) if card.status_pending_review?
      return false unless CrmCard::AUTHOR_EDITABLE.include?(card.status)
      return true if perms.can?(:moderate)

      # Ответственный известен и для новой карточки — CrmCard#responsible
      # резолвится через lead_event.assigned_to. «new_record? ⇒ можно любому»
      # позволяло завести карточку по чужому назначенному лиду (ревью #94).
      perms.can?("create_#{card.kind}") && card.responsible&.id == actor.id
    end

    def edit_denial(card, perms)
      return perms.denial if perms.denial
      return wrong_bot(card) if wrong_bot(card)
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
        card.sandbox = Telegram::BotContext.test? if card.new_record?
        next deny(edit_denial(card, perms)) unless can_edit?(card, actor, perms)

        allowed = Schema.for(card.kind).map(&:key)
        card.payload = card.payload.to_h.merge(values.to_h.stringify_keys.slice(*allowed)).compact
        refresh_check(card)
        card.save!
        ok(card)
      end
      card.persisted? ? card.with_lock(&apply) : apply.call
    end

    # Карточка живёт в боте, где её завели: песочница не трогает рабочие
    # карточки, рабочий бот — тестовые. export! проверку не проходит: джоб
    # выставляет контекст по самой карточке (ExportJob).
    def wrong_bot(card)
      return nil if card.sandbox? == Telegram::BotContext.test?

      card.sandbox? ? 'Это карточка из тестового бота — открой её там.' : 'Это рабочая карточка — в тестовом боте её не трогаем.'
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
      return if card.sandbox?

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

    def fail_export!(card, error:, attempt_token: nil, retryable: nil)
      message = error.to_s.truncate(500)
      result = card.with_lock do
        next deny('Карточка не выгружается.') unless card.status_exporting?
        next deny('Чужая попытка выгрузки — статус не трогаем.') if attempt_token && !attempt_current?(card, attempt_token)

        transition!(card, to: 'export_failed', actor: nil, comment: message)
        card.update!(export_error: message, export_retryable: retryable)
        ok(card)
      end
      notifier.export_failed(card) if result.ok?
      result
    end

    # record_export! может отказать (неверный формат номера) или упасть
    # (БД) уже после того, как CRM приняла заявку — crm_id к этому моменту
    # уже сохранён в export!, остаётся только не потерять карточку молча.
    def finalize_export!(card, outcome, attempt_token: nil)
      result = record_export!(card, crm_id: outcome.crm_id, mode: 'api', warning: outcome.warning,
                              attempt_token: attempt_token)
      result.ok? ? result : lost_export_status!(card, outcome, result.error, attempt_token: attempt_token)
    rescue StandardError => e
      lost_export_status!(card, outcome, "#{e.class}: #{e.message}", attempt_token: attempt_token)
    end

    def lost_export_status!(card, outcome, reason, attempt_token: nil)
      Rails.logger.error("[CrmCards::Workflow] card=#{card.id} создана в CRM #{outcome.crm_id}, но статус не записан: #{reason}")
      fail_export!(card, error: "Заявка уже создана в CRM под номером #{outcome.crm_id}, но статус не записан (#{reason}). " \
                                'Не повторяй выгрузку — поправь статус вручную.', attempt_token: attempt_token, retryable: false)
    end

    # Попытка актуальна, только если её токен до сих пор на карточке:
    # retry_export!/следующий export! заменяют или чистят его.
    def attempt_current?(card, token)
      card.reload.export_attempt_token == token
    end

    def notifier
      @notifier ||= Notifier.new
    end

    def exporter
      @exporter ||= LeadExporter.new
    end
  end
end
