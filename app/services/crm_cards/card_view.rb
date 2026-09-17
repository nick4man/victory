# frozen_string_literal: true

module CrmCards
  # Карточка CRM в личке: текст и кнопки под того, кто смотрит. Недоступной
  # зрителю кнопки нет вовсе — права всё равно перепроверяет Workflow, но
  # кнопка, которая всегда отвечает «нельзя», учит кнопки не нажимать.
  #
  # Только для личных сообщений: в тексте телефон клиента.
  module CardView
    KIND_TITLES = { 'lead' => 'Заявка в CRM', 'object' => 'Объект в CRM' }.freeze
    RETRY_HINT = 'Если это таймаут — сначала найди клиента в CRM по телефону: заявка могла создаться.'
    MANUAL_EXPORT_HINT = '📥 <b>Внеси объект в CRM вручную</b>: «Создать объект Продавца», поля — выше. ' \
                         'Копию договора приложи в CRM. Затем нажми «Внесено в CRM» и введи номер карточки.'

    module_function

    # @return [Hash] { text:, keyboard: } — контракт Wizard::Flow#finish
    def render(card, viewer:)
      { text: text(card), keyboard: keyboard(card, viewer, Permissions.for(viewer)) }
    end

    def text(card)
      lines = [header(card),
               "Статус: #{CrmCard::STATUS_LABELS[card.status]}",
               "Ответственный: #{escape(card.responsible.mention)} · обновлена #{Formatters::DateFormat.fmt_dt(card.updated_at)}",
               '']
      Schema.for(card.kind).each do |field|
        value = card.payload[field.key]
        next if value.nil? && !field.required

        lines << "#{field.label}: #{value.nil? ? '—' : escape(plain_value(field, value))}"
      end
      lines << ''
      lines.concat(staff_test_lines(card))
      lines.concat(check_lines(card))
      lines.concat(status_lines(card))
      lines.join("\n")
    end

    # Значение без HTML — для кнопок и для экранирования снаружи.
    def plain_value(field, value)
      case field.type
      when :phone, :phone_extra then format_phone(value.to_s)
      when :choice  then Schema.option_label(field, value) || value.to_s
      when :decimal then ActiveSupport::NumberHelper.number_to_delimited(value, delimiter: ' ', separator: ',')
      else value.to_s
      end
    end

    def keyboard(card, viewer, perms)
      return [] if perms.denial

      moderator = perms.can?(:moderate)
      owner = card.responsible&.id == viewer.id
      case card.status
      when 'draft', 'needs_rework' then author_rows(card) if owner || moderator
      when 'pending_review' then moderator_rows(card) if moderator
      when 'approved' then approved_rows(card, owner, moderator)
      when 'exporting' then [[button('🔁 Повторить выгрузку', "crm_card:#{card.id}:retry")]] if moderator && card.export_stale? && card.crm_id.blank?
      when 'export_failed' then [[button('🔁 Повторить выгрузку', "crm_card:#{card.id}:retry")]] if moderator && card.kind_lead? && card.crm_id.blank?
      end || []
    end

    # Объект вносит в CRM ответственный; заявка, не ушедшая в выгрузку за
    # 15 минут (джоб не встал в очередь), — повторяется модератором. Если
    # crm_id уже проставлен, Workflow#retry_export! всё равно откажет
    # (заявка уже создана в CRM) — кнопку, которая всегда отвечает «нельзя»,
    # не показываем вовсе (см. CardView doc-comment).
    def approved_rows(card, owner, moderator)
      return [[button('📥 Внесено в CRM', "wiz:s:crm_manual:#{card.id}")]] if card.kind_object? && (owner || moderator)

      [[button('🔁 Повторить выгрузку', "crm_card:#{card.id}:retry")]] if moderator && card.export_stale? && card.crm_id.blank?
    end

    def author_rows(card)
      rows = [[button('✏️ Изменить поле', "wiz:s:crm_edit:#{card.id}")]]
      rows << [button('📤 На модерацию', "crm_card:#{card.id}:submit")] if card.check_passed?
      rows
    end

    def moderator_rows(card)
      rows = [[button('✏️ Изменить поле', "wiz:s:crm_edit:#{card.id}"),
               button('↩️ На доработку', "wiz:s:crm_rework:#{card.id}")]]
      rows << [button('✅ Одобрить', "wiz:s:crm_approve:#{card.id}")] if card.check_passed?
      rows
    end

    def header(card)
      title = "📋 <b>#{KIND_TITLES[card.kind]} · карточка ##{card.id}</b>"
      card.lead_event_id ? "#{title} · лид ##{card.lead_event_id}" : title
    end

    # Эвристика StaffSubmissionDetector помечает лид «возможно, заявка
    # сотрудника» — и клиента, чьё имя совпало с именем сотрудника. Запрещать
    # по ней нельзя, но модератор должен это видеть. Лиды песочницы помечены
    # явно (metadata['sandbox']) и предупреждения не получают.
    def staff_test_lines(card)
      lead = card.lead_event
      return [] unless lead&.staff_test? && lead.metadata.to_h['sandbox'] != true

      ["⚠️ Лид помечен как возможная заявка сотрудника (#{escape(lead.staff_test_matched_by)}) — " \
       'проверь, настоящий ли это клиент.']
    end

    def check_lines(card)
      return ['🔍 Машинная проверка ещё не запускалась.'] if card.checked_at.nil?
      return ['🔍 Машинная проверка: ✅ пройдена'] if card.check_errors.blank?

      ["🔍 Машинная проверка: ❌ #{card.check_errors.size} замеч."] +
        card.check_errors.map { |e| "• #{escape(error_label(card, e['field']))}: #{escape(e['message'])}" }
    end

    def status_lines(card)
      case card.status
      when 'needs_rework'
        ['', "↩️ <b>Вернули на доработку</b> #{escape(card.reviewer&.mention)}: #{escape(card.last_rework_comment)}"]
      when 'approved'
        return ['', MANUAL_EXPORT_HINT] if card.kind_object?

        card.export_stale? ? ['', "⚠️ Выгрузка висит дольше 15 минут. #{RETRY_HINT}"] : []
      when 'exporting'
        card.export_stale? ? ['', "⚠️ Выгрузка висит дольше 15 минут. #{RETRY_HINT}"] : []
      when 'exported'
        exported_lines(card)
      when 'export_failed'
        ['', "⚠️ <b>Выгрузка не удалась:</b> #{escape(card.export_error)}", "<i>#{RETRY_HINT}</i>"]
      else []
      end
    end

    def exported_lines(card)
      lines = ['', "🟢 В CRM: #{escape(card.crm_id)} · #{Formatters::DateFormat.fmt_dt(card.exported_at)}"]
      lines << "⚠️ #{escape(card.export_error)}" if card.export_error.present?
      lines
    end

    def error_label(card, key)
      return 'Лид' if key == 'lead'

      Schema.field(card.kind, key)&.label || key
    end

    def format_phone(digits)
      return digits unless digits.match?(/\A7\d{10}\z/)

      "+7 #{digits[1, 3]} #{digits[4, 3]}-#{digits[7, 2]}-#{digits[9, 2]}"
    end

    def button(text, callback_data)
      { text: text, callback_data: callback_data }
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
