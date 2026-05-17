# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 7.2 — Формирует preview-сообщение в DM Оксане с inline-кнопками
    # [✅ Подтвердить][✏️ Изменить][✖️ Отмена] для подтверждения пакета задач.
    #
    # Внутри:
    #   1. Группирует tasks по assignee
    #   2. Для tasks с related_property_address — резолвит Property по адресу
    #      → Nextcloud::DealFolderResolver → optional share-link (Phase 7.8a)
    #   3. Включает uncertainties block
    #   4. Сохраняет preview_message_id / preview_chat_id в TaskBatch
    #
    # @example
    #   batch = TaskBatch.find(...)
    #   conf = Telegram::WorkBot::TaskBatchConfirmer.new(batch: batch)
    #   conf.call  # → постит preview + edits batch.preview_message_id
    class TaskBatchConfirmer
      class Error < StandardError; end

      PRIORITY_ICON = {
        'urgent' => '🔴',
        'high' => '🟠',
        'normal' => '⚪',
        'low' => '⚫'
      }.freeze

      KIND_ICON = {
        'call' => '📞',
        'show' => '🏠',
        'document' => '📄',
        'admin' => '⚙️',
        'other' => '📌'
      }.freeze

      def initialize(batch:, client: Telegram::Client.new, nc_client: nil)
        @batch     = batch
        @client    = client
        @nc_client = nc_client # для DI в тестах; nil → ленивая инициализация
      end

      def call
        director = @batch.created_by
        chat_id  = director.dm_chat_id || director.tg_user_id

        text = build_preview_text
        markup = build_keyboard

        msg = @client.send_message(text,
                                   chat_id: chat_id,
                                   parse_mode: 'HTML',
                                   reply_markup: markup)

        @batch.update!(preview_message_id: msg['message_id'], preview_chat_id: chat_id)
        msg
      end

      private

      def build_preview_text
        lines = []
        lines << "📋 <b>Подтверди пакет задач</b> (batch ##{@batch.id})"
        lines << ''

        tasks = @batch.tasks_payload
        if tasks.empty?
          lines << '<i>(пустой список задач — нечего подтверждать)</i>'
        else
          group_by_assignee(tasks).each do |assignee, group|
            lines << assignee_header(assignee)
            group.each_with_index { |t, _i| lines << format_task_line(t) }
            lines << ''
          end
        end

        unc = Array(@batch.parsed_payload['uncertainties'])
        if unc.any?
          lines << '⚠️ <b>Уточнения:</b>'
          unc.each { |u| lines << "  • #{escape(u)}" }
          lines << ''
        end

        lines << '<i>Транскрипт (PII-маскирован):</i>'
        lines << "<i>#{escape(@batch.transcript_redacted.to_s.truncate(400))}</i>"

        lines.join("\n")
      end

      def assignee_header(assignee)
        return '👤 <b>(нет получателя)</b>' if assignee.blank?

        user = TelegramUser.find_by_username(assignee) # rubocop:disable Rails/DynamicFindBy
        if user
          mention = user.tg_username.present? ? "@#{user.tg_username}" : user.display_name
          "👤 <b>#{escape(mention)}</b> (#{escape(user.first_name.to_s)})"
        else
          "👤 <b>@#{escape(assignee)}</b> ⚠️ <i>не найден в staff</i>"
        end
      end

      def format_task_line(task)
        kind_icon     = KIND_ICON[task[:kind].to_s] || '📌'
        priority_icon = PRIORITY_ICON[task[:priority].to_s] || '⚪'
        due_str       = task[:due_at] ? "до #{format_due_at(task[:due_at])}" : 'без срока'
        nc_link       = nc_link_for(task)

        line = "  #{kind_icon} #{priority_icon} #{escape(task[:title].to_s)} — <i>#{due_str}</i>"
        line += "\n     📁 <a href=\"#{nc_link}\">deal folder</a>" if nc_link
        line
      end

      def format_due_at(raw)
        return raw.strftime('%d.%m.%y %H:%M') if raw.is_a?(Time) || raw.is_a?(DateTime)

        t = begin
          Time.zone.parse(raw.to_s)
        rescue StandardError
          nil
        end
        t ? t.strftime('%d.%m.%y %H:%M') : raw.to_s
      rescue StandardError
        raw.to_s
      end

      # Резолвит related_property_address → Property → NC share-link.
      # Soft-fail на любой ошибке — preview не должен падать из-за NC.
      def nc_link_for(task)
        address = task[:related_property_address]
        return nil if address.blank?

        property = Property.where('address ILIKE ?', "%#{address}%").first
        return nil if property.nil?

        inquiry = Inquiry.find_by(property_id: property.id)
        resolver = Nextcloud::DealFolderResolver.for(property: property, inquiry: inquiry)
        return nil unless nc_client.exists?(resolver.parent_dir)

        share = Nextcloud::ShareLinkGenerator.for(path: resolver.path, ttl: 7.days,
                                                  created_by: @batch.created_by)
        share.url
      rescue StandardError => e
        Rails.logger.warn("[TaskBatchConfirmer] NC link skip for #{address.inspect}: #{e.class} #{e.message}")
        nil
      end

      def nc_client
        @nc_client ||= Nextcloud::Client.new
      end

      def group_by_assignee(tasks)
        tasks.group_by { |t| t[:assignee_username].to_s }
      end

      def build_keyboard
        {
          inline_keyboard: [
            [
              { text: '✅ Подтвердить', callback_data: "batch_confirm:#{@batch.id}:approve" },
              { text: '✖️ Отмена', callback_data: "batch_confirm:#{@batch.id}:cancel" }
            ]
          ]
        }
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
