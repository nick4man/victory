# frozen_string_literal: true

module Telegram
  module WorkBot
    # Задача по лиду с дедлайном: локальный Task + fc_next_action_at в Topnlab.
    # Общий путь для `/task` с аргументами и мастера «Задача с дедлайном».
    #
    # Сбой CRM задачу не отменяет: она уже создана в боте, а результат
    # сообщает, дошёл ли дедлайн до Topnlab, — мастер говорит об этом прямо.
    class LeadTaskCreator
      Result = Struct.new(:task, :crm, keyword_init: true) # crm: :ok | :skipped | :failed

      # @param assignee [TelegramUser, nil] nil — ответственный по лиду или автор
      def initialize(lead, due_date:, title:, actor:, assignee: nil, tg_message_id: nil)
        @lead = lead
        @due_date = due_date
        @title = title
        @actor = actor
        @assignee = assignee
        @tg_message_id = tg_message_id
      end

      def call
        task = ::Task.create!(
          lead_event: @lead,
          assignee: @assignee || @lead.assigned_to || @actor,
          created_by: @actor,
          title: @title.to_s[0, 255],
          due_at: due_at,
          topnlab_id: @lead.lead_ref.try(:crm_id).to_i.nonzero?,
          topnlab_type: 'order',
          tg_message_id: @tg_message_id
        )
        Result.new(task: task, crm: push_due_to_crm)
      end

      private

      def due_at
        @due_date.in_time_zone.end_of_day
      end

      def push_due_to_crm
        crm_id = @lead.lead_ref.try(:crm_id)
        return :skipped if crm_id.blank?

        Topnlab::Client.new.patch_entity(
          id: crm_id.to_i,
          type: 'order',
          fields: { fc_next_action_at: due_at.iso8601 }
        )
        :ok
      rescue StandardError => e
        Rails.logger.warn("[LeadTaskCreator] patch_entity failed: #{e.class}: #{e.message}")
        :failed
      end
    end
  end
end
