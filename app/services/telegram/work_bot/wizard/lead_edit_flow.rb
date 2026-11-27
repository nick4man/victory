# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Редактирование лида» (issue #277) — вход с карточки дашборда
      # (wiz:s:lead_edit:<id>): поле → значение → сохранение и перерисовка
      # карточки. Бот просит значение следующим сообщением в личке.
      #
      # Правится только metadata лида (имя/телефон/комментарий): поля CRM
      # живут в CrmCard и меняются через модерацию (crm_edit) — сюда они
      # намеренно не заведены, CRM-инвариант не трогаем.
      class LeadEditFlow < Flow
        include LeadPicking

        flow 'lead_edit', 'Редактирование лида'
        manager_only

        FIELDS = [
          ['👤 Имя', 'name'],
          ['📞 Телефон', 'phone'],
          ['💬 Комментарий', 'comment']
        ].freeze
        FIELD_HINTS = {
          'name' => 'Как зовут клиента — одной строкой.',
          'phone' => 'Телефон в любом виде — приведу к +7…',
          'comment' => 'Комментарий диспетчера — виден на карточке дашборда.'
        }.freeze
        NAME_MAX = 100
        COMMENT_MAX = 500

        # Контекст возврата с карточки дашборда (ревью #280): сегменты после
        # id лида в wiz:s:lead_edit:<id>[:<ctx>] — s<staff_id>:<staff_page>
        # (карточка сотрудника) или p<page> (страница списка лидов).
        # Сохраняется в ctx как строка 'return_to' и переживает весь wizard.
        def self.seed_extras(segments)
          first = segments[0].to_s
          if (m = first.match(/\As(\d+)\z/))
            { 'return_to' => "s#{m[1]}:#{DashboardPagination.normalize_page(segments[1])}" }
          elsif (m = first.match(/\Ap(\d+)\z/))
            { 'return_to' => "p#{DashboardPagination.normalize_page(m[1])}" }
          else
            {}
          end
        end

        def steps
          [
            lead_step,
            Step.new(id: 'field', kind: :choice, per_row: 1,
                     prompt: "Что меняем у лида ##{ctx['lead']}?",
                     options: FIELDS),
            Step.new(id: 'value', kind: :input,
                     prompt: "Пришли новое значение (#{field_label(ctx['field'])}) для лида ##{ctx['lead']}.",
                     hint: FIELD_HINTS[ctx['field']])
          ]
        end

        # Свой гейт вместо lead_gate из LeadPicking: закрытый лид редактировать
        # можно (контакт правят и после закрытия), deleted/staff_test — нельзя.
        def gate
          return nil if ctx['lead'].blank?
          return "⚠️ Лид ##{escape_html(ctx['lead'])} не найден (или удалён)." unless lead
          return "🚫 Лид ##{lead.id} тестовый — с ним работают только в тестовом боте." if ::CrmCards::Checker.sandbox_lead?(lead)
          return "🧪 Лид ##{lead.id} — тестовый (probe). Редактирование недоступно." if lead.staff_test?

          nil
        end

        def accept(step, value, manual: false)
          case step.id
          when 'lead'  then accept_lead(value)
          when 'field' then accept_field(value)
          when 'value' then accept_value(value)
          else [value, nil]
          end
        end

        def finish
          # Между вводом и финалом лид могли удалить или пометить probe —
          # перепроверяем, как CloseFlow перепроверяет закрытие.
          current = ::LeadEvent.find_by(id: ctx['lead'])
          return { text: '⚠️ Лид не найден (или удалён) — ничего не изменено.' } unless current
          return { text: "🧪 Лид ##{current.id} — тестовый (probe). Редактирование недоступно." } if current.staff_test?

          field = ctx['field']
          current.update!(metadata: current.metadata.merge(field => ctx['value']))
          # Якорная карточка в топике показывает имя/телефон — перерисовываем
          # той же механикой, что /stage и /assign (refresh! сам гасит ошибки).
          LeadAnnouncer.refresh!(current, client: client)

          # Карточка перерисовывается с тем же origin, с которого пришли:
          # сохранение тронуло updated_at и сдвинуло лид в начало сортировки
          # списка — без зафиксированного контекста «Назад» ушёл бы на
          # пересчитанную (неверную) страницу (ревью #280).
          card = DashboardLeadCard.new(lead: current, origin: return_origin).call
          { text: "✅ Лид ##{current.id}: #{field_label(field)} — обновлено.\n\n#{card.text}",
            keyboard: card.keyboard[:inline_keyboard] }
        end

        private

        # 's<staff_id>:<page>' → карточка сотрудника; 'p<page>' → страница
        # списка лидов; иначе — без origin (старое поведение).
        def return_origin
          case ctx['return_to'].to_s
          when /\As(\d+):(\d+)\z/
            { staff_id: Regexp.last_match(1).to_i, staff_page: Regexp.last_match(2).to_i }
          when /\Ap(\d+)\z/
            { list_page: Regexp.last_match(1).to_i }
          end
        end

        def accept_field(value)
          return [value, nil] if FIELDS.any? { |_, v| v == value }

          [nil, 'Неизвестное поле — выбери кнопкой.']
        end

        def accept_value(value)
          text = value.to_s.squish
          case ctx['field']
          when 'name'
            return [nil, 'Пустое имя — пришли хотя бы одно слово.'] if text.empty?
            return [nil, "Слишком длинно: #{text.length} символов, влезает #{NAME_MAX}."] if text.length > NAME_MAX

            [text, nil]
          when 'phone'
            normalized = Lead::Intake::ClientResolver.normalize_phone(text)
            return [nil, "«#{escape_html(text)}» не похоже на телефон — нужно минимум 10 цифр."] if normalized.nil?

            ["+#{normalized}", nil]
          when 'comment'
            return [nil, 'Пустой комментарий — пришли хотя бы одно слово.'] if text.empty?
            return [nil, "Слишком длинно: #{text.length} символов, влезает #{COMMENT_MAX}."] if text.length > COMMENT_MAX

            [text, nil]
          else
            [nil, 'Сначала выбери поле.']
          end
        end

        def field_label(field)
          FIELDS.to_h { |label, key| [key, label] }[field] || field.to_s
        end
      end
    end
  end
end
