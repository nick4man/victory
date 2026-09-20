# frozen_string_literal: true

module CrmCards
  # Уведомления конвейера карточек CRM — только в личку. В группу карточка
  # не уходит: там телефон клиента увидят все. Под карточкой лида в группе
  # меняется лишь кнопка со статусом (LeadAnnouncer.refresh!).
  #
  # Сбой Telegram конвейер не роняет: карточка уже в новом статусе, и
  # сотрудник увидит её через /cards.
  class Notifier
    def initialize(client: nil)
      @client = client
    end

    def submitted(card, moderators:)
      delivered = moderators.count { |moderator| deliver(moderator, "📥 <b>На модерацию</b> от #{escape(card.responsible.mention)}", card) }
      if delivered.zero?
        dm(card.responsible, '⚠️ Карточка на модерации, но ни одному модератору не удалось написать в личку. ' \
                        'Пусть директор откроет чат с ботом, нажмёт «Start» и наберёт /cards.')
      end
      refresh_lead_anchor(card)
    end

    def returned(card, comment:)
      deliver(card.responsible, "↩️ <b>Карточка ##{card.id} вернулась на доработку</b>: #{escape(comment)}", card)
      refresh_lead_anchor(card)
    end

    # Одобрение больше не отправляет карточку в CRM — это решает руководитель
    # (право export). Поэтому автору сообщаем, что карточка ждёт его решения,
    # а самому руководителю карточка уходит с кнопкой выгрузки.
    def approved(card, exporters: [])
      deliver(card.responsible,
              "✅ <b>Карточка ##{card.id} одобрена</b> #{escape(card.reviewer&.mention)} — " \
              'ждёт решения руководителя о выгрузке в CRM.', card)
      delivered = exporters.count { |boss| deliver(boss, "📤 <b>Ждёт выгрузки в CRM</b> · карточка ##{card.id}", card) }
      # Некому и не доставили — разные беды с разным лечением: в первом случае
      # чинят таблицу должностей, во втором руководителю надо открыть чат с
      # ботом. Свалить их в одно сообщение — отправить чинить исправное.
      if exporters.empty?
        dm(card.reviewer, "⚠️ Карточка ##{card.id} одобрена, но решение о выгрузке принять некому: " \
                          'права выгрузки нет ни у кого из сотрудников. Проверь должности в CRM.')
      elsif delivered.zero?
        dm(card.reviewer, "⚠️ Карточка ##{card.id} одобрена, но написать о ней в личку никому из руководителей " \
                          'не удалось. Пусть откроет чат с ботом, нажмёт «Start» и наберёт /cards.')
      end
      refresh_lead_anchor(card)
    end

    def released(card)
      text = if card.kind_lead?
               "📤 <b>Карточка ##{card.id}</b>: #{escape(card.released_by&.mention)} разрешил выгрузку — отправляю в CRM."
             else
               "📤 <b>Объект по карточке ##{card.id}</b>: #{escape(card.released_by&.mention)} разрешил внесение — " \
                 'внеси его в CRM и отметь номер.'
             end
      deliver(card.responsible, text, card)
      refresh_lead_anchor(card)
    end

    def exported(card, warning: nil)
      text = "🟢 <b>Карточка ##{card.id} в CRM:</b> #{escape(card.crm_id)}"
      text += "\n⚠️ #{escape(warning)}" if warning.present?
      [card.responsible, card.reviewer].compact.uniq(&:id).each { |user| dm(user, text) }
      refresh_lead_anchor(card)
    end

    def export_failed(card)
      Permissions.moderators.each { |moderator| deliver(moderator, "⚠️ <b>Выгрузка карточки ##{card.id} не удалась</b>", card) }
      dm(card.responsible, "⚠️ Выгрузка карточки ##{card.id} в CRM не удалась — у модератора кнопка повтора.")
      refresh_lead_anchor(card)
    end

    private

    # @return [Boolean] доставлено ли
    def deliver(user, header, card)
      view = CardView.render(card, viewer: user)
      dm(user, "#{header}\n\n#{view[:text]}", keyboard: view[:keyboard])
    end

    def dm(user, text, keyboard: nil)
      return false unless user&.can_dm?

      opts = { chat_id: user.dm_chat_id, parse_mode: 'HTML' }
      opts[:reply_markup] = { inline_keyboard: keyboard } if keyboard.present?
      client.send_message(text, **opts)
      true
    rescue Telegram::Client::Error => e
      Rails.logger.warn("[CrmCards::Notifier] DM to #{user.mention} failed: #{e.message}")
      false
    rescue StandardError => e
      # сетевые ошибки Net::HTTP клиент Telegram не оборачивает
      Rails.logger.error("[CrmCards::Notifier] DM to #{user.mention} failed unexpectedly: #{e.class}: #{e.message}")
      false
    end

    def refresh_lead_anchor(card)
      return unless card.lead_event

      Telegram::WorkBot::LeadAnnouncer.refresh!(card.lead_event, client: client)
    rescue StandardError => e
      Rails.logger.warn("[CrmCards::Notifier] refresh anchor lead=#{card.lead_event_id}: #{e.class}: #{e.message}")
    end

    def client
      @client ||= Telegram::Client.new
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
