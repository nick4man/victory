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
  #   true  — алерт ушёл
  #   false — не почтовая джоба, подавлено троттлом либо некому слать
  class MailFailureAlert
    # Джобы, чья смерть означает непришедшее письмо.
    #
    # Все мейлеры через `deliver_later` идут одним классом
    # `ActionMailer::MailDeliveryJob`, поэтому список закрывает их скопом.
    # Дописывать сюда нужно только собственные джобы, которые шлют почту
    # сами (как InquiryNotificationJob).
    MAIL_JOB_CLASSES = %w[
      ActionMailer::MailDeliveryJob
      ActionMailer::DeliveryJob
      InquiryNotificationJob
    ].freeze

    # Потеря письма — не transient-сбой, но при лежащем SMTP умирают сразу
    # десятки джоб. Час на связку (джоба + класс ошибки) держит директоров
    # в курсе без alert fatigue.
    THROTTLE_TTL = 1.hour

    def self.call(job:, exception:)
      new(job: job, exception: exception).call
    end

    def initialize(job:, exception:)
      @job = job || {}
      @exception = exception
    end

    def call
      return false unless mail_job?
      return false unless throttle_allows?

      cascade = Telegram::CriticalRecipients.resolve
      if cascade.empty?
        Rails.logger.error("[MailFailureAlert] письмо потеряно, но получателей алерта нет: #{summary}")
        return false
      end

      deliver_to(cascade)
      true
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

      Rails.logger.info(
        "[MailFailureAlert] throttled — #{throttle_key} " \
        "(suppressed=#{Telegram::AlertThrottle.suppressed_count(key: throttle_key)})"
      )
      false
    end

    def deliver_to(cascade)
      text = alert_text(cascade)
      client = Telegram::Client.new
      cascade.each do |recipient|
        chat_id = recipient.dm_chat_id || recipient.tg_user_id
        next if chat_id.blank?

        client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
      rescue StandardError => e
        Rails.logger.warn("[MailFailureAlert] DM to #{recipient.mention}: #{e.message}")
      end
    end

    def alert_text(cascade)
      tier_note = cascade.fallback? ? "\n<i>(routed to #{cascade.tier} tier — directors недоступны)</i>" : ''
      error_line = escape("#{exception.class}: #{exception.message.to_s.truncate(160)}")

      "📭 <b>Письмо не доставлено</b>\n" \
        "Кому: <code>#{escape(recipient_email)}</code>\n" \
        "Отправитель: <code>#{escape(mailer_signature)}</code>\n" \
        "Ошибка: <code>#{error_line}</code>\n" \
        "Попыток: #{job['retry_count'].to_i + 1}, потеряно #{Time.current.strftime('%d.%m.%y %H:%M')}" \
        "#{suppress_note}#{tier_note}\n\n" \
        '<i>Письмо ушло в dead-очередь и само не повторится.</i>'
    end

    def suppress_note
      count = Telegram::AlertThrottle.suppressed_count(key: throttle_key)
      count.positive? ? "\n<i>(подавлено #{count} похожих за последний час)</i>" : ''
    end

    # Свой регекс, а не URI::MailTo::EMAIL_REGEXP: тот якорный (\A...\z) и
    # ищет совпадение по всей строке, поэтому внутри дампа джобы не находит
    # ничего. Здесь нужен именно поиск подстроки.
    EMAIL_IN_TEXT = /[\w+.-]+@[a-z\d.-]+\.[a-z]+/i

    # У MailDeliveryJob адрес лежит вглубине хеша аргументов, у собственных
    # джоб структура своя. Ищем первое, что похоже на адрес, вместо разбора
    # формата — он у каждой джобы разный.
    def recipient_email
      job.to_s[EMAIL_IN_TEXT] || '—'
    end

    # Для MailDeliveryJob первые два аргумента — класс мейлера и его метод.
    #
    # Разбираем по шагу с проверкой типа: у собственных джоб `args` — это
    # массив скаляров (InquiryNotificationJob → [90]), и `dig` по нему падает
    # с NoMethodError. Падение здесь глушило АЛЕРТ ЦЕЛИКОМ.
    def mailer_signature
      first = job['args'].is_a?(Array) ? job['args'][0] : nil
      args = first.is_a?(Hash) ? first['arguments'] : nil
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
