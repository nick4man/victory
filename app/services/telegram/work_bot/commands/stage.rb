# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Изменение стадии лида: `/stage показ` reply на якорную карточку.
      #
      # Поддерживаемые русские синонимы стадий — STAGE_MAP. После обновления
      # текущая якорная карточка перерисовывается (меняется эмодзи статуса в
      # первой строке). Для contract/deal дополнительно постится тизер в #СДЕЛКА.
      #
      # Не manager-only — стадии меняет любой сотрудник по своему лиду.
      class Stage < Base
        STAGE_MAP = {
          'первый-контакт' => 'first_contact',
          'первый_контакт' => 'first_contact',
          'контакт' => 'first_contact',
          'показ' => 'show',
          'договор' => 'contract',
          'сделка' => 'deal',
          'выиграно' => 'closed_won',
          'победа' => 'closed_won',
          'проиграно' => 'closed_lost',
          'отказ' => 'closed_lost'
        }.freeze

        def handle
          # Phase 15 — resolve_lead! сначала «съест» lead_id из @args если есть.
          lead = resolve_lead!
          return reply(lead_not_found_hint('stage показ')) unless lead

          new_stage = STAGE_MAP[@args.downcase.strip]
          unless new_stage
            return reply("Неизвестная стадия. Доступно: <code>#{STAGE_MAP.keys.join(', ')}</code>")
          end

          return reply("🚫 Стадию меняет только assignee (#{lead.assigned_to&.mention || 'не назначен'}) или manager.") unless assignee_or_manager?(lead)

          result = Telegram::WorkBot::LeadStageTransition.new(lead, new_stage, actor: tg_user, client: client).call
          if result.success?
            reply("Лид ##{lead.id}: #{result.prev_stage} → <b>#{result.new_stage}</b> ✅")
          else
            reply("⚠️ #{result.message}")
          end
        end
      end
    end
  end
end
