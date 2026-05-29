# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 16.7 — renderer + sender для AnomalyDetector findings.
    #
    # Получает Anomaly, рендерит Russian HTML markdown (без сленга — «существенно
    # выше», не «2σ deviation»), шлёт DM каждому recipient из CriticalRecipients
    # cascade (director → admin → manager fallback).
    #
    # Контракт: `.call(anomaly)` → Integer (number of DMs sent). 0 если cascade
    # пустой (cascade logs error сам).
    class AnomalyNotifier
      # Метрика → (заголовок, подсказка для action). Соответствует AnomalyDetector::Anomaly#metric.
      METRIC_LABELS = {
        overdue_rate: {
          title: 'доля просроченных задач',
          current_label: 'сейчас',
          baseline_label: 'в среднем по команде',
          hint: 'Возможные причины: перегрузка, неверная оценка сроков, технический блок. ' \
                'Стоит уточнить у сотрудника.'
        },
        first_contact_delay_30m_miss: {
          title: 'доля лидов без первого контакта в 30 минут',
          current_label: 'сейчас',
          baseline_label: 'в среднем по команде',
          hint: 'Возможные причины: лиды поступают вне рабочих часов, проблемы с уведомлениями, ' \
                'нет времени отрабатывать вовремя. Стоит проговорить дальше работать.'
        },
        completion_rate_drop: {
          title: 'выполнение задач',
          current_label: 'за неделю',
          baseline_label: 'было раньше',
          hint: 'Возможные причины: снижение нагрузки, отпуск, болезнь, переключение на другой ' \
                'фронт работ. Стоит уточнить статус.'
        }
      }.freeze

      def self.call(anomaly)
        new(anomaly).call
      end

      def initialize(anomaly)
        @anomaly = anomaly
      end

      def call
        text = render
        recipients = Telegram::CriticalRecipients.resolve
        return 0 if recipients.empty?

        sent = 0
        recipients.each do |recipient|
          next if recipient.dm_chat_id.blank?

          send_dm(recipient, text)
          sent += 1
        rescue StandardError => e
          Rails.logger.warn("[AnomalyNotifier] DM failed for #{recipient.mention}: #{e.class} #{e.message}")
        end
        sent
      end

      private

      def render
        meta = METRIC_LABELS.fetch(@anomaly.metric)

        lines = []
        lines << '🔔 <b>Потенциальная проблема у сотрудника</b>'
        lines << ''
        lines << "#{mention(@anomaly.staff)} — #{meta[:title]} существенно выше остальных:"
        lines << "  • #{meta[:current_label]}: <b>#{format_percent(@anomaly.value)}</b>"
        lines << "  • #{meta[:baseline_label]}: <b>#{format_percent(@anomaly.baseline)}</b>"
        lines << "  • отклонение от средней: <b>#{@anomaly.deviation_label}</b>"
        lines << ''
        lines << meta[:hint]
        lines << ''
        lines << '<i>Уведомление формируется при отклонении показателя от командной нормы. ' \
                 'Повтор — не раньше следующих суток.</i>'
        lines.join("\n")
      end

      def mention(staff)
        if staff.tg_username.present?
          "@#{staff.tg_username}"
        else
          staff.first_name.to_s
        end
      end

      def format_percent(rate)
        "#{(rate * 100).round(0)}%"
      end

      def send_dm(recipient, text)
        Telegram::Client.new.send_message(
          text,
          chat_id: recipient.dm_chat_id,
          parse_mode: 'HTML'
        )
      end
    end
  end
end
