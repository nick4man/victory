# frozen_string_literal: true

module Telegram
  module WorkBot
    module ShowReports
      # BOTTLENECK — что происходит по нажатию [✅ Сохранить] в превью отчёта.
      #
      # Порядок не случаен: сначала БД (статус, стадия, задача) под локом, потом
      # Telegram (пост в топик, DM собственнику) вне лока — как в
      # TaskBatchConfirmCallback: TG-вызовы долгие и не должны держать строку.
      #
      # Задача «обратная связь собственнику до 11:00» — это I4 из ревью Шага 4:
      # самый жёсткий дедлайн регламента, единственный без таймера. Теперь у
      # него есть Task + Sla::TasksWatchdogJob.
      class Finalizer
        MOSCOW = 'Europe/Moscow'
        FEEDBACK_HOUR = 11

        # День в день, максимум — следующее утро до 11:00 (Шаг 4, этап 3.1).
        # Отчёт, надиктованный после полуночи, относится к «сегодня».
        def self.feedback_due_at(conducted_at)
          local = conducted_at.in_time_zone(MOSCOW)
          day = local.hour < FEEDBACK_HOUR ? local.to_date : local.to_date + 1
          Time.find_zone(MOSCOW).local(day.year, day.month, day.day, FEEDBACK_HOUR, 0)
        end

        def initialize(report:, actor:, client: Telegram::Client.new)
          @report = report
          @actor  = actor
          @client = client
          @lead   = report.lead_event
        end

        def call
          confirmed = false
          @report.with_lock do
            @report.reload
            return :already_done unless @report.status_pending_confirm?

            @report.confirm!
            stamp_first_show!
            create_feedback_task!
            confirmed = true
          end
          return :already_done unless confirmed

          clear_assigned_conductor!
          move_stage!
          post_to_topic
          send_owner_draft
          nudge_segment if @lead.reload.segment.blank?
          :confirmed
        end

        def owner_reachable?
          owner_user&.tg_user_id.present?
        end

        private

        def owner_user
          @owner_user ||= @report.property&.owner_user
        end

        # BOTTLENECK — назначение «кто показывает» одноразовое: оно про конкретный
        # показ. Без сброса каждый следующий отчёт по этому лиду приписывался бы
        # тому же человеку, перебивая и LLM, и фактического рассказчика, — то есть
        # врала бы сама ось эксперимента «сегмент × кто показывал» (найдено ревью).
        def clear_assigned_conductor!
          return if @lead.metadata['show_conductor_id'].blank?

          @lead.update!(metadata: @lead.metadata.except('show_conductor_id', 'show_conductor_set_at',
                                                        'show_conductor_set_by'))
        rescue StandardError => e
          Rails.logger.warn("[ShowReports::Finalizer#clear_assigned_conductor!] #{e.class}: #{e.message}")
        end

        def stamp_first_show!
          return if @lead.first_show_at.present? && @lead.first_show_at <= @report.conducted_at

          @lead.update!(first_show_at: @report.conducted_at)
        end

        def create_feedback_task!
          task = ::Task.create!(
            lead_event: @lead,
            assignee: @report.reported_by,
            created_by: @actor,
            title: "Обратная связь собственнику: #{address}"[0, 255],
            kind: 'call',
            priority: 'high',
            status: 'open',
            due_at: self.class.feedback_due_at(@report.conducted_at),
            assigned_at: Time.current
          )
          @report.update!(feedback_task_id: task.id)
        end

        # Только вперёд: new/first_contact → show. Лид на contract/deal не трогаем.
        def move_stage!
          return unless ['new', 'first_contact'].include?(@lead.current_stage)

          result = LeadStageTransition.new(@lead, 'show', actor: @actor, client: @client).call
          Rails.logger.warn("[ShowReports::Finalizer] stage → show skipped: #{result.message}") unless result.success?
        rescue StandardError => e
          Rails.logger.warn("[ShowReports::Finalizer#move_stage!] #{e.class}: #{e.message}")
        end

        def post_to_topic
          return if @lead.anchor_message_id.blank?

          objections = @report.objections_list.any? ? @report.objections_list.join(', ') : 'без возражений'
          text = "🏠 <b>Показ #{Formatters::DateFormat.fmt_dt(@report.conducted_at)}</b> — " \
                 "#{escape(@report.conducted_by.display_name)} · #{@report.outcome_label}\n" \
                 "Возражения: #{escape(objections)}" \
                 "#{@report.next_step.present? ? "\nДальше: #{escape(@report.next_step)}" : ''}"
          @client.send_message(text, chat_id: @lead.tg_chat_id, message_thread_id: @lead.anchor_thread_id,
                                     reply_to_message_id: @lead.anchor_message_id, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReports::Finalizer#post_to_topic] #{e.message}")
        end

        def send_owner_draft
          reporter = @report.reported_by
          chat_id = reporter.dm_chat_id || reporter.tg_user_id
          return if chat_id.blank?

          due = Formatters::DateFormat.fmt_dt(self.class.feedback_due_at(@report.conducted_at))
          text = "✉️ <b>Собственнику до #{due}</b> (задача ##{@report.feedback_task_id}):\n\n" \
                 "#{escape(@report.owner_message)}\n\n" \
                 "<i>#{owner_reachable? ? 'Собственник в Telegram — можно отправить кнопкой.' : 'У собственника нет Telegram — скопируй и отправь сам.'}</i>"
          @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML', reply_markup: owner_keyboard)
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReports::Finalizer#send_owner_draft] #{e.message}")
        end

        def owner_keyboard
          row = []
          row << { text: '📤 Отправить в TG собственнику', callback_data: "show_report:#{@report.id}:owner_push" } if owner_reachable?
          row << { text: '✅ Отправил(а) сам(а)', callback_data: "show_report:#{@report.id}:owner_sent" }
          { inline_keyboard: [row] }
        end

        def nudge_segment
          reporter = @report.reported_by
          chat_id = reporter.dm_chat_id || reporter.tg_user_id
          return if chat_id.blank?

          @client.send_message(SegmentKeyboard.prompt_text, chat_id: chat_id, parse_mode: 'HTML',
                                                            reply_markup: SegmentKeyboard.for(@lead))
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReports::Finalizer#nudge_segment] #{e.message}")
        end

        def address
          @report.property&.address.presence || "лид ##{@lead.id}"
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
