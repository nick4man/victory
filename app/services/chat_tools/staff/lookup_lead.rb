# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 7.5 — Поиск лида/сделки по id, имени или телефону.
    module LookupLead
      def self.schema
        {
          type: 'function',
          function: {
            name: 'lookup_lead',
            description: 'Найти лид (LeadEvent) по id, имени клиента, телефону или crm_id. ' \
                         'Используй когда сотрудник спрашивает про конкретного клиента или сделку.',
            parameters: {
              type: 'object',
              required: ['query'],
              properties: {
                query: {
                  type: 'string',
                  description: 'id LeadEvent ("42"), имя клиента ("Анна Петрова"), телефон ' \
                               '("89991234567"), или crm_id ("117338580").'
                }
              }
            }
          }
        }
      end

      def self.call(args = {})
        query = args[:query].to_s.strip
        return { error: 'empty_query' } if query.empty?

        leads = find_leads(query).first(5)
        return { error: 'not_found', query: query } if leads.empty?

        { count: leads.size, leads: leads.map { |le| serialize(le) } }
      end

      def self.find_leads(query)
        # id поиск
        return [::LeadEvent.find_by(id: query.to_i)].compact if query.match?(/\A\d{1,4}\z/)

        # По имени / тел / crm_id (через metadata jsonb)
        normalized = query.downcase.gsub(/\D/, '')
        ::LeadEvent.where(
          "metadata->>'name' ILIKE :q OR metadata->>'phone' LIKE :phone OR metadata->>'crm_id' = :crm",
          q: "%#{query}%", phone: "%#{normalized}%", crm: normalized
        ).order(created_at: :desc).limit(5).to_a
      end

      def self.serialize(le)
        {
          id: le.id,
          source: le.source,
          stage: le.current_stage,
          topic: le.anchor_topic_key,
          assigned_to: le.assigned_to&.mention,
          assigned_at: le.assigned_at&.strftime('%d.%m.%y %H:%M'),
          first_contact_at: le.first_contact_at&.strftime('%d.%m.%y %H:%M'),
          closed_at: le.closed_at&.strftime('%d.%m.%y %H:%M'),
          client_name: le.metadata.is_a?(Hash) ? le.metadata['name'] : nil,
          anchor_url: le.anchor_url
        }
      end
    end
  end
end
