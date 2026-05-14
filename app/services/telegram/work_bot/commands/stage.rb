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

          prev = lead.current_stage
          return reply("Лид уже на стадии <b>#{prev}</b>") if prev == new_stage

          apply_stage!(lead, new_stage)
          update_anchor_card!(lead)
          maybe_mirror_to_deal(lead, new_stage)

          reply("✅ #{prev} → <b>#{new_stage}</b>")
        end

        private

        def find_lead_via_reply
          reply_to = message['reply_to_message']
          return nil unless reply_to

          LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
        end

        def apply_stage!(lead, new_stage)
          attrs = { current_stage: new_stage }
          attrs[:first_contact_at] = Time.current if new_stage == 'first_contact' && lead.first_contact_at.nil?
          attrs[:closed_at]        = Time.current if new_stage.start_with?('closed_')
          lead.update!(attrs)
        end

        def update_anchor_card!(lead)
          return if lead.anchor_message_id.blank?

          text = Telegram::WorkBot::LeadAnnouncer.new(lead, client: client).format_card_text
          client.edit_message_text(
            text,
            chat_id: lead.tg_chat_id,
            message_id: lead.anchor_message_id,
            parse_mode: 'HTML'
          )
        rescue StandardError => e
          Rails.logger.warn("[Commands::Stage] edit_message_text failed: #{e.message}")
        end

        def maybe_mirror_to_deal(lead, new_stage)
          return unless ['contract', 'deal'].include?(new_stage)

          Telegram::WorkBot::DealMirror.new(lead, client: client).post
        end
      end
    end
  end
end
