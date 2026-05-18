# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 4B — `/doc` command — управление DocumentRequirement checklist.
      #
      # Usage (reply на якорную карточку лида):
      #   /doc                              — full checklist status
      #   /doc passport+ snils+             — batch mark received
      #   /doc egrn?                        — request from client
      #   /doc contract+verified            — atomic received+verified
      #   /doc poa@reject:no_notary         — mark rejected с reason
      #   /doc init                         — auto-build checklist (Phase 4C)
      #
      # Authorization: assignee лида ИЛИ manager_or_director (Phase 13 Iter 41).
      class Doc < Base
        def handle
          lead = find_lead_via_reply
          return reply('⚠️ Команда должна быть reply на якорную карточку лида.') unless lead

          unless assignee_or_manager?(lead)
            return reply("🚫 Управлять документами может assignee (#{lead.assigned_to&.mention || 'не назначен'}) или manager.")
          end

          # /doc init — Phase 4C auto-build checklist из template registry
          if args.to_s.strip == 'init'
            res = ::DocumentChecklist::Builder.new(lead_event: lead, actor: tg_user).call
            if res.success?
              created_lines = res.created.map { |r| "  • #{r.ru_label}" }
              skipped_note = res.skipped.empty? ? '' : "\n<i>Пропущено (уже было): #{res.skipped.size}</i>"
              return reply("📋 <b>Чек-лист создан</b> по шаблону <code>#{res.template_key}</code>\n" \
                           "Добавлено: <b>#{res.created.size}</b>\n#{created_lines.join("\n")}#{skipped_note}\n\n" \
                           '<i>Запросить от клиента: <code>/doc passport? snils? egrn?</code></i>')
            else
              return reply("⚠️ Auto-build failed: #{res.error.to_s.truncate(160)}")
            end
          end

          # /doc без args — формат текущий checklist
          if args.to_s.strip.empty?
            return reply(::DocumentChecklist::Manager.new(lead_event: lead, actor: tg_user).format_status)
          end

          # /doc <tokens> — apply changes
          parse_result = ::DocumentChecklist::Tokenizer.new(args).parse
          if parse_result.tokens.empty? && parse_result.errors.any?
            return reply("⚠️ #{parse_result.errors.first}")
          end

          apply_result = ::DocumentChecklist::Manager.new(lead_event: lead, actor: tg_user)
                                                    .apply(parse_result.tokens)
          if apply_result.success?
            error_suffix = parse_result.errors.any? ? "\n⚠️ #{parse_result.errors.join('; ')}" : ''
            reply("✅ #{apply_result.message}#{error_suffix}")
          else
            reply("⚠️ #{apply_result.message}")
          end
        end

        private

        def find_lead_via_reply
          reply_to = message['reply_to_message']
          return nil unless reply_to

          LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
        end
      end
    end
  end
end
