# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/cards` — карточки CRM: у сотрудника свои карточки в работе, у
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
          sections(perms).each do |title, all_cards|
            cards = all_cards.first(LIMIT)
            count = all_cards.size > cards.size ? "#{cards.size} из #{all_cards.size}" : cards.size
            lines << '' << "<b>#{title}</b> (#{count})"
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
          list = [['📝 Мои карточки в работе', own_cards]]
          list << ['⏳ На модерации', ::CrmCard.in_current_bot.status_pending_review.order(:submitted_at).to_a] if
            perms.can?(:moderate)
          # Держателю права выгрузки нужен свой список: иначе одобренную карточку
          # ему негде найти — только в том единственном уведомлении, которое он
          # мог смахнуть.
          list << ['📤 Ждут решения о выгрузке', awaiting_release] if perms.can?(:export)
          list << ['⚠️ Сбои выгрузки', export_problems] if perms.can?(:moderate) || perms.can?(:export)
          list
        end

        def awaiting_release
          ::CrmCard.in_current_bot.status_approved.where(released_at: nil).order(:reviewed_at).to_a
        end

        # «Мои» — по CrmCard#responsible, а не по author_id: заявку ведёт
        # текущий ответственный по лиду. Все карточки, ещё не ушедшие в CRM:
        # мастер карточки по лиду отсылает сюда, если карточка уже отправлена.
        def own_cards
          ::CrmCard.in_current_bot.includes(lead_event: :assigned_to).where.not(status: 'exported')
                   .order(updated_at: :desc).to_a
                   .select { |c| c.responsible&.id == tg_user.id }
        end

        # Застрявшее одобрение (джоб не встал в очередь) — тоже сбой: иначе
        # такую заявку не найти ни в одном списке.
        def export_problems
          ::CrmCard.in_current_bot.where(status: %w[export_failed exporting approved]).order(:updated_at).to_a
                   .select { |c| c.status_export_failed? || c.export_stale? }
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
