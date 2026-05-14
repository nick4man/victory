# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/lead <phone> <name>, <текст>` — manual вход в конвейер из TG-чата.
      # Создаёт Inquiry, который через `after_create_commit :push_to_work_bot`
      # запускает Lead::Intake.call(source: 'manual') → LeadAnnouncer публикует
      # карточку в #ДИСПЕТЧЕРСКОЙ с inline-кнопками маршрутизации.
      #
      # Manager-only — чтобы спам в TG-чате не превращался в лиды.
      class Lead < Base
        manager_only

        LEAD_REGEX = /\A
          \s*(?<phone>\+?\d[\d\s\-()]{9,18}\d)   # 10-20 цифр с разделителями
          [\s,]*                                   # сепаратор опционален (phone-only тоже ok)
          (?<name>\p{L}[\p{L}\s-]{1,40})?      # имя (опц)
          [\s,]*
          (?<rest>.*)                              # свободный текст
        \Z/xm

        FORMAT_HINT = 'Формат: <code>/lead +79001234567 Анна, бюджет 6 млн, ЖК Северный</code>'

        def handle
          match = LEAD_REGEX.match(args.to_s)
          return reply("⚠️ Не понимаю формат.\n#{FORMAT_HINT}") unless match

          phone = match[:phone].to_s.strip
          name  = match[:name].to_s.strip.presence || 'Клиент из TG'
          rest  = match[:rest].to_s.strip

          inquiry = ::Inquiry.create!(
            name: name,
            phone: phone,
            message: rest.presence,
            inquiry_type: 'quick_inquiry',
            source: 'tg_manual'
          )

          reply("✅ Лид принят (Inquiry ##{inquiry.id}). Карточка в #ДИСПЕТЧЕРСКОЙ.")
        rescue ActiveRecord::RecordInvalid => e
          reply("⚠️ Не удалось создать лид: #{e.record.errors.full_messages.join(', ')}")
        end
      end
    end
  end
end
