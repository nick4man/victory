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
          new_stage = STAGE_MAP[args.downcase.strip]
          unless new_stage
            return reply("Неизвестная стадия. Доступно: <code>#{STAGE_MAP.keys.join(', ')}</code>")
          end

          lead = find_lead_via_reply
          return reply('⚠️ Команда должна быть reply на якорную карточку лида.') unless lead

          result = Telegram::WorkBot::LeadStageTransition.new(lead, new_stage, actor: tg_user, client: client).call
          if result.success?
            reply("✅ #{result.prev_stage} → <b>#{result.new_stage}</b>")
          else
            reply("⚠️ #{result.message}")
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
