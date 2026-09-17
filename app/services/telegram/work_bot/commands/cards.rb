# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/cards` — карточки CRM: у сотрудника свои черновики и возвраты, у
      # модератора ещё очередь модерации и сбои выгрузки. Только в личке:
      # в списке имена клиентов.
      class Cards < Base
        LIMIT = 10

        def handle
          unless message.dig('chat', 'type') == 'private'
            return reply('📋 Карточки CRM — только в личке с ботом: в списке имена клиентов.')
          end

          perms = ::CrmCards::Permissions.for(tg_user)
          return reply("🚫 #{escape_html(perms.denial)}") if perms.denial

          lines = ['📋 <b>Карточки CRM</b>']
          rows = []
          sections(perms).each do |title, cards|
            lines << '' << "<b>#{title}</b> (#{cards.size})"
            lines << 'Пусто.' if cards.empty?
            cards.each do |card|
              lines << "• #{escape_html(line_for(card))}"
              rows << [{ text: line_for(card).truncate(60), callback_data: "crm_card:#{card.id}:view" }]
            end
          end
          reply(lines.join("\n"), reply_markup: { inline_keyboard: rows })
        end

        private

        def sections(perms)
          list = [['📝 Мои черновики, возвраты и объекты к внесению', own_cards]]
          if perms.can?(:moderate)
            list << ['⏳ На модерации', ::CrmCard.status_pending_review.order(:submitted_at).limit(LIMIT).to_a]
            list << ['⚠️ Сбои выгрузки', export_problems]
          end
          list
        end

        # «Мои» — по CrmCard#responsible, а не по author_id: заявку ведёт
        # текущий ответственный по лиду. Одобренный объект остаётся в списке,
        # пока ответственный не отметит номер карточки в CRM.
        def own_cards
          ::CrmCard.includes(:lead_event).where(status: ::CrmCard::AUTHOR_EDITABLE + ['approved'])
                   .order(updated_at: :desc).to_a
                   .select { |c| c.responsible&.id == tg_user.id && (!c.status_approved? || c.kind_object?) }
                   .first(LIMIT)
        end

        # Застрявшее одобрение (джоб не встал в очередь) — тоже сбой: иначе
        # такую заявку не найти ни в одном списке.
        def export_problems
          ::CrmCard.where(status: %w[export_failed exporting approved]).order(:updated_at).to_a
                   .select { |c| c.status_export_failed? || c.export_stale? }
                   .first(LIMIT)
        end

        def line_for(card)
          name = card.payload['name'].presence || card.payload['owner_name'].presence || 'без имени'
          kind = card.kind_lead? ? 'заявка' : 'объект'
          "##{card.id} · #{kind} · #{name} · #{::CrmCard::STATUS_LABELS[card.status]}"
        end
      end
    end
  end
end
