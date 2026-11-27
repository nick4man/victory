# frozen_string_literal: true

module Telegram
  module WorkBot
    # Issue #277 — карточка лида в дашборде (callback dashboard:lead:<id>).
    #
    # Компактный рендер ключевых полей лида для DM руководителя: контакт,
    # стадия, ответственный, метки, ip-контекст источника (#275) и таймлайн
    # последних событий из metadata-историй LeadEvent. Inline-клавиатура
    # действий переиспользует существующие callback-механики (stage:, assign:,
    # spam:, wiz:s:lead_edit:) — логика не дублируется, кнопки лишь ссылаются
    # на те же обработчики, что и якорная карточка в топике.
    #
    # Удаление — soft-delete по правилу #1 (deleted_at, не destroy) и только
    # через обязательный confirm: dashboard:lead:<id>:del → :del:yes.
    class DashboardLeadCard
      Result = Struct.new(:text, :keyboard, keyword_init: true)

      TIMELINE_LIMIT = 5
      UA_MAX = 80

      STAGE_LABELS = {
        'new' => 'новый',
        'first_contact' => 'первый контакт',
        'show' => 'показ',
        'contract' => 'договор',
        'deal' => 'сделка',
        'closed_won' => 'выигран',
        'closed_lost' => 'проигран'
      }.freeze

      def initialize(lead:)
        @lead = lead
      end

      def call
        Result.new(text: card_text, keyboard: card_keyboard)
      end

      # Экран подтверждения удаления — обязательный шаг перед soft-delete.
      def confirm_delete
        Result.new(
          text: "🗑 <b>Удалить лид ##{@lead.id}?</b>\n\n" \
                "👤 #{escape(lead_name)}\n\n" \
                'Лид скроется из списков и дашборда (soft-delete, запись останется в базе). ' \
                'Выгрузка в CRM будет заблокирована.',
          keyboard: { inline_keyboard: [
            [{ text: '✅ Да, удалить', callback_data: "dashboard:lead:#{@lead.id}:del:yes" }],
            [{ text: '✖️ Отмена', callback_data: "dashboard:lead:#{@lead.id}" }]
          ] }
        )
      end

      # Soft-delete по правилу #1: выставляем deleted_at, НЕ destroy.
      def perform_delete(actor:)
        # Страницу считаем до update!: апдейт тронет updated_at и сдвинет
        # позицию лида в детерминированной сортировке списка.
        page = back_page
        @lead.update!(
          deleted_at: Time.current,
          metadata: @lead.metadata.merge('deleted_by' => actor.mention)
        )
        Result.new(
          text: "🗑 <b>Лид ##{@lead.id} удалён.</b>\n\n" \
                'Запись скрыта из списков и дашборда (soft-delete). Выгрузка в CRM заблокирована.',
          keyboard: { inline_keyboard: [
            [{ text: '⬅️ К списку лидов', callback_data: DashboardPagination.leads_page_callback(page) }]
          ] }
        )
      end

      private

      def card_text
        meta = @lead.metadata || {}
        lines = ["🎯 <b>Лид ##{@lead.id}</b> · #{stage_label}"]
        lines << labels_line(meta)
        lines << "👤 #{escape(lead_name)}#{phone_suffix(meta['phone'])}"
        lines << "✉️ #{escape(meta['email'])}" if meta['email'].present?
        title = @lead.lead_ref.try(:title)
        lines << "🏷 #{escape(title)}" if title.present?
        lines << "💬 #{escape(meta['comment'].to_s.truncate(300))}" if meta['comment'].present?
        lines << escape(meta['summary'].to_s.truncate(300)) if meta['summary'].present?
        lines << "💰 #{escape(meta['budget'])}" if meta['budget'].present?
        lines << ip_line(meta)
        lines << assignee_line
        lines << "🕐 #{Formatters::DateFormat.fmt_dt(@lead.created_at)}"
        lines.concat(timeline_lines)
        lines.compact.join("\n")
      end

      def card_keyboard
        rows = []
        rows << stage_row if @lead.open?
        rows << [
          { text: '👤 Назначить', callback_data: "assign:#{@lead.id}" },
          { text: '🚫 Спам', callback_data: "spam:#{@lead.id}" }
        ]
        rows << [{ text: '✏️ Редактировать', callback_data: "wiz:s:lead_edit:#{@lead.id}" }]
        rows << [{ text: '🗑 Удалить', callback_data: "dashboard:lead:#{@lead.id}:del" }]
        rows << [
          { text: '⬅️ Назад', callback_data: DashboardPagination.leads_page_callback(back_page) },
          { text: '🔄 Обновить', callback_data: "dashboard:lead:#{@lead.id}" }
        ]
        { inline_keyboard: rows }
      end

      # «Назад» — на ту страницу списка, где лид лежит сейчас: сортировка
      # списка детерминирована (updated_at desc, id desc), поэтому страница
      # вычисляется позицией лида, а не хранится в callback_data.
      def back_page
        @back_page ||= begin
          ahead = LeadEvent.open.real.where(
            'updated_at > ? OR (updated_at = ? AND id > ?)',
            @lead.updated_at, @lead.updated_at, @lead.id
          ).count
          (ahead / DashboardPagination::PAGE_SIZE) + 1
        end
      end

      def stage_label
        emoji = LeadAnnouncer::STAGE_EMOJI[@lead.current_stage] || '🆕'
        "#{emoji} #{STAGE_LABELS[@lead.current_stage] || @lead.current_stage}"
      end

      # Те же кнопки стадий, что на якорной карточке (LeadAnnouncer#stage_row):
      # callback_data идентичны — обрабатывает существующий StageCallback.
      def stage_row
        [
          { text: '📅 Показ',   callback_data: "stage:#{@lead.id}:show" },
          { text: '✍️ Договор', callback_data: "stage:#{@lead.id}:contract" }
        ]
      end

      # Метки — те же бейджи, что на якорной карточке (LeadAnnouncer): сегмент,
      # приоритет, возвратный клиент, тип услуги. Ключи metadata общие.
      def labels_line(meta)
        badges = [@lead.segment_label]
        badges << { 'urgent' => '🔥 URGENT', 'high' => '⚡ HIGH' }[meta['priority'].to_s]
        badges << '🔄 возвратный' if meta['returning_client']
        badges << {
          'express' => '🔵 EXPRESS', 'investment' => '🟣 INVESTMENT',
          'cma' => '🟠 SALE CMA', 'buyer_scan' => '🟢 BUYER SCAN'
        }[meta['service_type'].to_s]
        badges.compact.join(' · ')
      end

      # ip-контекст источника из #275: SiteSource кладёт ip/user_agent в meta.
      # Строки нет у TG-лидов и лидов до #275 — тогда опускаем.
      def ip_line(meta)
        return nil if meta['ip'].blank?

        ua = meta['user_agent'].to_s.truncate(UA_MAX)
        "🌐 IP: #{escape(meta['ip'])}#{ua.present? ? " · #{escape(ua)}" : ''}"
      end

      def assignee_line
        return "👤 Назначен: #{escape(@lead.assigned_to.display_name)}" if @lead.assigned_to

        '👤 Не назначен'
      end

      # Компактный таймлайн последних событий: смены стадий, назначения,
      # маршрутизация, сегмент, заметки — из metadata-историй LeadEvent.
      def timeline_lines
        events = timeline_events
        return [] if events.empty?

        ['', '<b>История:</b>'] + events.map { |at, text| "  · #{Formatters::DateFormat.fmt_dt(at)} — #{text}" }
      end

      def timeline_events
        meta = @lead.metadata || {}
        events = []
        events.concat(history_events(meta['stage_history']) do |e|
          "стадия: #{e['from']} → #{e['to']} (#{escape(e['by'].to_s)})"
        end)
        events.concat(history_events(meta['assign_history']) do |e|
          text = e['from'].present? ? "переназначен: #{e['from']} → #{e['to_mention']}" : "назначен: #{e['to_mention']}"
          "#{escape(text)} (#{escape(e['by_mention'].to_s)})"
        end)
        events.concat(history_events(meta['routing_history']) do |e|
          "топик: #{e['from']} → #{e['to']} (#{escape(e['by'].to_s)})"
        end)
        events.concat(history_events(meta['segment_history']) do |e|
          "сегмент: #{e['from'] || '—'} → #{e['to']}"
        end)
        events.concat(history_events(meta['notes']) do |e|
          "заметка: #{escape(e['text'].to_s.truncate(60))} (#{escape(e['by'].to_s)})"
        end)
        events.select { |at, _| at.present? }.sort_by(&:first).reverse.first(TIMELINE_LIMIT)
      end

      def history_events(entries)
        Array(entries).map { |e| [parse_at(e['at']), yield(e)] }
      end

      def parse_at(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def lead_name
        (@lead.metadata || {})['name'].presence || "Лид ##{@lead.id}"
      end

      def phone_suffix(phone)
        phone.present? ? ", #{escape(phone)}" : ''
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
