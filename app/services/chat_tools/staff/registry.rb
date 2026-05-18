# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 7.5 — Tool registry для Llm::StaffChatResponder. Аналог
    # ChatTools::Registry, но для staff-side (security boundary — клиентский
    # чатбот НЕ должен иметь доступ к этим tools).
    module Registry
      HANDLERS = {
        'list_my_open_tasks' => ChatTools::Staff::ListMyOpenTasks,
        'lookup_task' => ChatTools::Staff::LookupTask,
        'lookup_lead' => ChatTools::Staff::LookupLead,
        'agent_status' => ChatTools::Staff::AgentStatus,
        'nextcloud_lookup_deal' => ChatTools::Staff::NextcloudLookupDeal,
        'nextcloud_list_templates' => ChatTools::Staff::NextcloudListTemplates,
        'kpi_for' => ChatTools::Staff::KpiFor,
        # Phase 5.1 — DocumentRequirement checklist status
        'document_checklist_status' => ChatTools::Staff::DocumentChecklistStatus
      }.freeze

      module_function

      def schemas
        HANDLERS.values.map(&:schema)
      end

      def call(name, args)
        handler = HANDLERS[name.to_s]
        return { error: 'unknown_tool', tool: name } unless handler

        handler.call(deep_symbolize(args))
      rescue StandardError => e
        Rails.logger.warn("[ChatTools::Staff] #{name} failed: #{e.class} #{e.message}")
        { error: 'tool_failed', tool: name, message: e.message.to_s.truncate(180) }
      end

      def deep_symbolize(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
        when Array then obj.map { |v| deep_symbolize(v) }
        else            obj
        end
      end
    end
  end
end
