# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/close выиграно` / `/close проиграно причина:цена` — закрывает лид.
      # Эффективно делает то же, что `/stage выиграно`, плюс парсит causes и
      # пишет причину в LeadEvent.metadata['close_reason'] + Topnlab note.
      #
      # Manager-only: проигранный лид требует подтверждения руководителя
      # (предотвращает быстрое закрытие агентом без эскалации).
      class Close < Base
        manager_only

        OUTCOME_MAP = {
          'выиграно' => 'closed_won',
          'победа' => 'closed_won',
          'won' => 'closed_won',
          'проиграно' => 'closed_lost',
          'отказ' => 'closed_lost',
          'lost' => 'closed_lost'
        }.freeze

        def handle
          # Phase 15 — resolve_lead! «съест» lead_id из @args если есть.
          lead = resolve_lead!
          return reply(lead_not_found_hint('close выиграно')) unless lead

          outcome_key, reason = parse_args
          new_stage = OUTCOME_MAP[outcome_key.to_s.downcase]
          unless new_stage
            return reply('Формат: <code>/close выиграно</code> или <code>/close &lt;lead_id&gt; проиграно причина:цена</code>')
          end

          result = Telegram::WorkBot::LeadClosure.new(lead, new_stage, actor: tg_user, reason: reason, client: client).call
          unless result.success?
            return reply("⚠️ #{result.message}")
          end

          icon = new_stage == 'closed_won' ? '✅' : '❌'
          msg  = "#{icon} Лид ##{lead.id} закрыт: <b>#{new_stage}</b>"
          msg += " (#{escape_html(reason)})" if reason.present?
          reply(msg)
        end

        private

        def parse_args
          parts = @args.to_s.strip.split(/\s+/, 2)
          [parts[0], parts[1].to_s.sub(/\A(причина|reason)\s*:\s*/i, '').presence]
        end
      end
    end
  end
end
