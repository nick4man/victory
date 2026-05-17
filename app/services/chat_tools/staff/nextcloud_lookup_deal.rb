# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 7.5 — Резолвит deal-folder в Nextcloud для Property + опц.
    # генерирует share-link (с TTL 7d). Soft-fail если NC недоступен.
    module NextcloudLookupDeal
      def self.schema
        {
          type: 'function',
          function: {
            name: 'nextcloud_lookup_deal',
            description: 'Найти deal-folder в Nextcloud по Property id или адресу. ' \
                         'Возвращает path, exists?, share_link (опц). Используй когда ' \
                         'сотрудник спрашивает «где документы по квартире», «папка сделки».',
            parameters: {
              type: 'object',
              required: ['query'],
              properties: {
                query: {
                  type: 'string',
                  description: 'Property id (число) или фрагмент адреса.'
                },
                generate_share: {
                  type: 'boolean',
                  description: 'Если true — создать public share-link с TTL 7d.'
                }
              }
            }
          }
        }
      end

      def self.call(args = {})
        query = args[:query].to_s.strip
        return { error: 'empty_query' } if query.empty?

        property = find_property(query)
        return { error: 'property_not_found', query: query } if property.nil?

        inquiry  = Inquiry.find_by(property_id: property.id)
        resolved = Nextcloud::DealFolderResolver.for(property: property, inquiry: inquiry)
        nc       = Nextcloud::Client.new
        exists   = nc.exists?(resolved.parent_dir) && nc.exists?(resolved.path)

        result = {
          property_id: property.id,
          address: property.address,
          folder_path: resolved.path,
          parent_exists: nc.exists?(resolved.parent_dir),
          deal_folder_exists: exists
        }

        if args[:generate_share] && exists
          share = Nextcloud::ShareLinkGenerator.for(path: resolved.path, ttl: 7.days)
          result[:share_url] = share.url
          result[:share_password] = share.password
          result[:share_expires_at] = share.expires_at&.strftime('%d.%m.%y')
        end

        result
      rescue Nextcloud::Client::Forbidden => e
        { error: 'sensitive_path', message: e.message }
      rescue StandardError => e
        Rails.logger.warn("[NextcloudLookupDeal] #{e.class}: #{e.message}")
        { error: 'nc_unavailable', message: e.message }
      end

      def self.find_property(query)
        return Property.find_by(id: query.to_i) if query.match?(/\A\d{1,7}\z/)

        Property.where('address ILIKE ?', "%#{query}%").first
      end
    end
  end
end
