# frozen_string_literal: true

module Telegram
  module WorkBot
    module ShowReports
      # BOTTLENECK — превью отчёта о показе в DM рассказчику с кнопками
      # [✅ Сохранить] [👤 Показывал(а): …] [✖️ Отмена]. Аналог TaskBatchConfirmer.
      # Без подтверждения запись не попадает в метрики — LLM ошибается, и
      # человек должен это увидеть до того, как цифра ушла в отчёт директору.
      class Confirmer
        def initialize(report:, client: Telegram::Client.new)
          @report = report
          @client = client
        end

        def call
          chat_id = @report.reported_by.dm_chat_id || @report.reported_by.tg_user_id
          msg = @client.send_message(preview_text, chat_id: chat_id, parse_mode: 'HTML', reply_markup: keyboard)
          @report.update!(preview_message_id: msg['message_id'], preview_chat_id: chat_id)
          msg
        end

        def preview_text
          lead = @report.lead_event
          lines = ["🏠 <b>Подтверди отчёт о показе</b> (##{@report.id})", '']
          lines << "Объект: #{escape(address)}"
          lines << "Покупатель: #{escape(lead.metadata['name'].presence || "лид ##{lead.id}")} · #{lead.segment_label}"
          lines << "Показывал(а): <b>#{escape(@report.conducted_by.display_name)}</b>"
          lines << "Когда: #{Formatters::DateFormat.fmt_dt(@report.conducted_at)}"
          lines << "Исход: <b>#{@report.outcome_label}</b>"
          lines << "Возражения: #{@report.objections_list.any? ? escape(@report.objections_list.join(', ')) : '—'}"
          lines << "Названная цена: #{price_line}" if @report.offered_price.present?
          lines << "Дальше: #{escape(@report.next_step)}" if @report.next_step.present?
          if @report.uncertainties.any?
            lines << ''
            lines << '⚠️ <b>Уточнения:</b>'
            @report.uncertainties.each { |u| lines << "  • #{escape(u)}" }
          end
          lines << ''
          lines << '<i>Черновик собственнику (пришлю после сохранения):</i>'
          lines << "<i>#{escape(@report.owner_message.to_s.truncate(400))}</i>"
          lines.join("\n")
        end

        def keyboard
          toggle = @report.conducted_by_director? ? '👤 Показывал(а) я' : '👑 Показывал руководитель'
          {
            inline_keyboard: [
              [{ text: '✅ Сохранить', callback_data: "show_report:#{@report.id}:approve" }],
              [{ text: toggle, callback_data: "show_report:#{@report.id}:toggle_conductor" }],
              [{ text: '✖️ Отмена', callback_data: "show_report:#{@report.id}:cancel" }]
            ]
          }
        end

        private

        def address
          @report.property&.address.presence || @report.lead_event.metadata['summary'].to_s.truncate(80).presence || 'объект не определён'
        end

        def price_line
          "#{ActiveSupport::NumberHelper.number_to_delimited(@report.offered_price.to_i, delimiter: ' ')} ₽"
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
