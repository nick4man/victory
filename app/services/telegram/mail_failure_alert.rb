# frozen_string_literal: true

module Telegram
  # Алерт о безвозвратно потерянном письме.
  #
  # Зачем: 10.09.26 выяснилось, что почта с noreply@victory62.org не уходила
  # с 30.06.26 — mail.ru закрыл SMTP на тарифе. Никто об этом не узнал:
  # `deliver_later` считает успехом постановку в очередь, бот отвечал
  # «Код отправлен», а письма тихо оседали в dead-очереди Sidekiq —
  # 457 штук за 16.05–10.09.26, включая 39 уведомлений по заявкам с сайта.
  #
  # Ловим именно СМЕРТЬ джобы (`death_handlers`), а не каждую ошибку
  # (`error_handlers`): промежуточные ретраи — шум, потеря письма — событие.
  #
  # Контракт:
  #   Telegram::MailFailureAlert.call(job: sidekiq_job_hash, exception: e) -> bool
  #   true  — алерт доставлен хотя бы одному получателю
  #   false — не почтовая джоба, подавлено троттлом, некому слать либо
  #           ни один DM не ушёл
  class MailFailureAlert
    # Джобы, чья смерть означает непришедшее письмо.
    #
    # Мейлеры через `deliver_later` идут одним классом
    # `ActionMailer::MailDeliveryJob`. Остальные — собственные джобы, которые
    # зовут `deliver_now` внутри себя, поэтому обёртки не получают: их
    # приходится перечислять поимённо (`grep -rl deliver_ app/jobs`).
    MAIL_JOB_CLASSES = %w[
      ActionMailer::MailDeliveryJob
      ActionMailer::DeliveryJob
      InquiryNotificationJob
      ViewingNotificationJob
      PropertyValuationJob
      PropertyValuationFollowUpJob
      PropertyValuationCompletedJob
    ].freeze

    # Потеря письма — не transient-сбой, но при лежащем SMTP умирают сразу
    # десятки джоб. Час на связку (джоба + класс ошибки) держит получателей
    # в курсе без alert fatigue.
    THROTTLE_TTL = 1.hour

    # Ищем адрес ТОЛЬКО в аргументах мейлера. Раньше грепали весь хеш джобы —
    # а к моменту смерти в нём лежит и `error_message`, поэтому в «Кому»
    # попадал адрес, выдранный из текста SMTP-ошибки (на реальных 457
    # мёртвых письмах — 19 раз чужой адрес против 5 верных).
    EMAIL_IN_TEXT = /[\w+.-]+@[a-z\d.-]+\.[a-z]+/i

    def self.call(job:, exception:)
      new(job: job, exception: exception).call
    end

    def initialize(job:, exception:)
      @job = job || {}
      @exception = exception
    end

    def call
      return false unless mail_job?

      # Получателей резолвим ДО троттла: иначе пустой каскад «съедал» бы
      # часовой слот и глушил все последующие алерты о потере писем.
      cascade = Telegram::CriticalRecipients.resolve
      if cascade.empty?
        Rails.logger.error("[MailFailureAlert] письмо потеряно, но получателей алерта нет: #{summary}")
        return false
      end

      return false unless throttle_allows?

      delivered = deliver_to(cascade)
      return true if delivered.positive?

      Rails.logger.error("[MailFailureAlert] письмо потеряно, но ни один DM не ушёл: #{summary}")
      false
    rescue StandardError => e
      Rails.logger.error("[MailFailureAlert] #{e.class}: #{e.message}")
      false
    end

    private

    attr_reader :job, :exception

    def mail_job?
      MAIL_JOB_CLASSES.include?(job_class)
    end

    # ActiveJob прячет реальный класс в `wrapped`, plain Sidekiq::Job кладёт
    # его в `class`. Проверяем оба поля.
    def job_class
      @job_class ||= (job['wrapped'].presence || job['class']).to_s
    end

    def throttle_key
      @throttle_key ||= "mail_failure:#{job_class}:#{exception.class.name}"
    end

    def throttle_allows?
      return true if Telegram::AlertThrottle.allow?(key: throttle_key, ttl: THROTTLE_TTL)

      Rails.logger.info("[MailFailureAlert] throttled — #{throttle_key}")
      false
    end

    # @return [Integer] сколько получателей реально получили алерт
    def deliver_to(cascade)
      text = alert_text(cascade)
      client = Telegram::Client.new
      cascade.count do |recipient|
        chat_id = recipient.dm_chat_id || recipient.tg_user_id
        next false if chat_id.blank?

        client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        true
      rescue StandardError => e
        Rails.logger.warn("[MailFailureAlert] DM to #{recipient.mention}: #{e.message}")
        false
      end
    end

    def alert_text(cascade)
      tier_note = cascade.fallback? ? "\n<i>(routed to #{cascade.tier} tier — directors недоступны)</i>" : ''
      error_line = escape("#{exception.class}: #{exception.message.to_s.truncate(160)}")

      "📭 <b>Письмо не доставлено</b>\n" \
        "#{addressee_line}" \
        "Отправитель: <code>#{escape(mailer_signature)}</code>\n" \
        "Ошибка: <code>#{error_line}</code>\n" \
        "Попыток: #{job['retry_count'].to_i + 1}, потеряно #{Time.current.strftime('%d.%m.%y %H:%M')}" \
        "#{tier_note}\n\n" \
        '<i>Письмо ушло в dead-очередь и само не повторится.</i>'
    end

    # Собственные джобы принимают id записи, а не адрес (InquiryNotificationJob
    # → `arguments: [39]`). Показываем что есть: без этого строка «Кому: —»
    # не даёт руководителю ни одной зацепки, кого именно не дождались.
    def addressee_line
      email = recipient_email
      return "Кому: <code>#{escape(email)}</code>\n" if email

      args = mailer_arguments
      return '' if args.blank?

      "Аргументы: <code>#{escape(args.inspect.truncate(80))}</code>\n"
    end

    def recipient_email
      mailer_arguments.to_s[EMAIL_IN_TEXT]
    end

    # Аргументы, с которыми звали мейлер/джобу. ActiveJob кладёт их в
    # args[0]['arguments']; plain Sidekiq::Job — прямо в args.
    def mailer_arguments
      first = job['args'].is_a?(Array) ? job['args'][0] : nil
      first.is_a?(Hash) ? first['arguments'] : job['args']
    end

    # Для MailDeliveryJob первые два аргумента — класс мейлера и его метод.
    # У собственных джоб там id записи, поэтому откатываемся на имя класса.
    def mailer_signature
      args = mailer_arguments
      return job_class unless args.is_a?(Array) && args[0].is_a?(String)

      args[1].is_a?(String) ? "#{args[0]}##{args[1]}" : args[0]
    end

    def summary
      "#{job_class} / #{exception.class}: #{exception.message.to_s.truncate(120)}"
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
