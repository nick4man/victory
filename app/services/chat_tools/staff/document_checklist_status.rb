# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 5.1 — Статус document checklist по лиду.
    # Connects Phase 4 DocumentRequirement к staff Q&A — agent в qna топике
    # может спросить «сколько документов открыто на лиде #145?» вместо
    # /doc reply на якорь.
    #
    # Returns aggregate counts + overdue list + sample required documents.
    module DocumentChecklistStatus
      def self.schema
        {
          type: 'function',
          function: {
            name: 'document_checklist_status',
            description: 'Получить статус document checklist по лиду — сколько ' \
                         'документов получено/просрочено/в ожидании, плюс top-overdue. ' \
                         'Используй когда спрашивают про docs/документы/SLA по конкретному lead_id.',
            parameters: {
              type: 'object',
              required: ['lead_id'],
              properties: {
                lead_id: {
                  type: 'integer',
                  description: 'id LeadEvent (e.g. 145)'
                }
              }
            }
          }
        }
      end

      def self.call(args = {})
        lead_id = args[:lead_id].to_i
        return { error: 'invalid_lead_id' } if lead_id.zero?

        lead = ::LeadEvent.find_by(id: lead_id)
        return { error: 'lead_not_found', lead_id: lead_id } if lead.nil?

        reqs = ::DocumentRequirement.where(lead_event_id: lead.id)
        return empty_checklist(lead) if reqs.empty?

        build_status(lead, reqs)
      end

      def self.empty_checklist(lead)
        {
          lead_id: lead.id,
          client_name: lead.metadata.is_a?(Hash) ? lead.metadata['name'] : nil,
          total: 0,
          message: 'Чек-лист пуст. Используй /doc init на якоре чтобы создать default.'
        }
      end

      def self.build_status(lead, reqs)
        counts = reqs.group(:status).count

        overdue_records = reqs.overdue.order(:requested_at).first(5)
        overdue_summary = overdue_records.map do |r|
          {
            kind: r.kind,
            label: r.ru_label,
            requested_at: r.requested_at&.strftime('%d.%m.%y'),
            overdue_factor: r.overdue_factor&.round(2)
          }
        end

        # Top still-needed (status in [not_requested, requested])
        pending_records = reqs.where(status: %w[not_requested requested]).order(:kind).first(8)
        pending_summary = pending_records.map { |r| { kind: r.kind, label: r.ru_label, status: r.status } }

        progress_pct = compute_progress(reqs)

        {
          lead_id: lead.id,
          client_name: lead.metadata.is_a?(Hash) ? lead.metadata['name'] : nil,
          assigned_to: lead.assigned_to&.mention,
          total: reqs.size,
          counts: counts,
          progress_pct: progress_pct,
          overdue_count: overdue_records.size,
          overdue_top5: overdue_summary,
          pending: pending_summary
        }
      end

      def self.compute_progress(reqs)
        total = reqs.size
        return 0 if total.zero?

        done = reqs.where(status: %w[verified approved]).count
        (done * 100.0 / total).round
      end
    end
  end
end
