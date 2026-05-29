# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 7.5 — Список шаблонов из НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ.
    # Опц. фильтр по keyword (агентский / ДКП / аренда / etc).
    module NextcloudListTemplates
      def self.schema
        {
          type: 'function',
          function: {
            name: 'nextcloud_list_templates',
            description: 'Список шаблонов договоров и документов из Nextcloud. ' \
                         'Используй когда сотрудник спрашивает «где шаблон договора», ' \
                         '«дай образец ДКП», «какие есть формы».',
            parameters: {
              type: 'object',
              properties: {
                keyword: {
                  type: 'string',
                  description: 'Фильтр по фрагменту имени (case-insensitive). ' \
                               'Пустой → все шаблоны.'
                },
                generate_share_for: {
                  type: 'string',
                  description: 'Точное имя файла → сгенерировать share-link для него.'
                }
              }
            }
          }
        }
      end

      def self.call(args = {})
        catalog = Nextcloud::TemplateCatalog.new

        if args[:generate_share_for].present?
          name = args[:generate_share_for].to_s
          path = catalog.path_for(name)
          return { error: 'template_not_found', name: name } if path.nil?

          share = Nextcloud::ShareLinkGenerator.for(path: path, ttl: 7.days)
          return {
            name: name,
            path: path,
            share_url: share.url,
            share_password: share.password,
            share_expires_at: share.expires_at&.strftime('%d.%m.%y')
          }
        end

        items = catalog.list
        if args[:keyword].present?
          items = items.select do |i|
            i[:name].to_s.downcase.include?(args[:keyword].to_s.downcase)
          end
        end
        files = items.select { |i| i[:type] == :file }.first(20)

        { count: files.size, templates: files.map { |i| { name: i[:name], size: i[:size] } } }
      rescue StandardError => e
        Rails.logger.warn("[NextcloudListTemplates] #{e.class}: #{e.message}")
        { error: 'nc_unavailable', message: e.message }
      end
    end
  end
end
