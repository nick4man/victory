# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # BOTTLENECK — `/show <текст>` reply на карточку или `/show <lead_id> <текст>` в DM:
      # отчёт о показе текстом, когда голосовое неудобно (в машине с клиентом,
      # в шумном подъезде). Лид задан явно — LLM его не угадывает.
      class Show < Base
        def handle
          lead = resolve_lead!
          return reply(lead_not_found_hint('show 12 показ прошёл, кухня не понравилась')) unless lead

          text = @args.to_s.strip
          if text.blank?
            return reply('Формат: <code>/show &lt;lead_id&gt; &lt;что сказали покупатели&gt;</code> в личке или ' \
                         '<code>/show &lt;текст&gt;</code> reply на карточку.')
          end

          result = ShowReports::Intake.new(
            reporter: tg_user,
            transcript_raw: text,
            transcript_redacted: Privacy::TranscriptRedactor.call(text),
            source: 'text',
            chat_id: message.dig('chat', 'id'),
            lead: lead,
            client: client
          ).call
          return reply(result.message) unless result.ok

          reply('✅ Принял, превью отчёта — в личке.') if message.dig('chat', 'type') != 'private'
        end
      end
    end
  end
end
