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
        'document_checklist_status' => ChatTools::Staff::DocumentChecklistStatus,
        # Iter 59 — director self-audit: «какие лиды я направил», «какие задания я давал»
        'director_self_audit' => ChatTools::Staff::DirectorSelfAudit,
        # Phase 15 — control panel tools
        'search_group_messages' => ChatTools::Staff::SearchGroupMessages,
        'search_all_tasks'      => ChatTools::Staff::SearchAllTasks,
        'search_all_leads'      => ChatTools::Staff::SearchAllLeads
      }.freeze

      module_function

      def schemas
        HANDLERS.values.map(&:schema)
      end

      # @param name    [String] имя tool'а из HANDLERS
      # @param args    [Hash]   аргументы от LLM
      # @param asked_by [TelegramUser, nil] caller-context (для security проверок
      #   в tools которые принимают этот kwarg, например director_self_audit).
      #   Tools которые arity=1 — игнорируют (kwarg dropped Ruby-side).
      def call(name, args, asked_by: nil)
        handler = HANDLERS[name.to_s]
        return { error: 'unknown_tool', tool: name } unless handler

        symbolised = deep_symbolize(args)
        if handler.method(:call).parameters.any? { |type, n| %i[key keyreq].include?(type) && n == :asked_by }
          handler.call(symbolised, asked_by: asked_by)
        else
          handler.call(symbolised)
        end
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
