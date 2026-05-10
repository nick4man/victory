# frozen_string_literal: true

module ChatTools
  # Returns a richer payload for a single object. The bot calls this when
  # the user references a specific listing by slug or after another tool
  # surfaced a candidate object that needs full details.
  module GetPropertyDetails
    def self.schema
      {
        type: 'function',
        function: {
          name: 'get_property_details',
          description: 'Полная информация по конкретному объекту по его slug. ' \
                       'Используй когда нужны детали (этаж, площади, фото, описание).',
          parameters: {
            type: 'object',
            required: %w[slug],
            properties: {
              slug: { type: 'string', description: 'URL-slug объекта (как в адресной строке)' }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args)
      slug = args.is_a?(Hash) ? args[:slug].to_s : args.to_s
      p = Property.in_advertising.friendly.find(slug)
      {
        id:            p.id,
        slug:          p.slug,
        title:         ChatTools::Format.sanitize_text(p.title),
        property_type: p.property_type&.slug,
        deal_type:     p.deal_type,
        price:         p.price&.to_i,
        price_text:    p.price_formatted,
        rooms:         p.rooms,
        area:          p.area&.to_f,
        area_unit:     p.property_type&.slug == 'land' ? 'соток' : 'м²',
        area_display:  ChatTools::Format.area_display(p),
        land_area_m2:  p.respond_to?(:land_area_m2) ? p.land_area_m2&.to_f : nil,
        living_area:   p.living_area&.to_f,
        kitchen_area:  p.kitchen_area&.to_f,
        floor:         p.floor,
        total_floors:  p.total_floors,
        building_year: p.building_year,
        condition:     p.condition,
        district:      ChatTools::Format.sanitize_text(p.district),
        metro_station: ChatTools::Format.sanitize_text(p.metro_station),
        metro_distance_m: p.metro_distance,
        address:       ChatTools::Format.sanitize_text(p.address),
        description:   ChatTools::Format.sanitize_text(p.description.to_s).to_s.truncate(1500),
        amenities:     amenities(p),
        agent:         agent_contact(p),
        url:           ChatTools::Url.property_path(p.slug)
      }.compact
    rescue ActiveRecord::RecordNotFound
      { error: 'not_found', slug: slug }
    end

    # Lets the bot answer "Кто ведёт этот объект?" / "На какой телефон звонить?"
    # Falls back gracefully when the assigned agent has no phone in CRM.
    def self.agent_contact(p)
      agent = p.user
      return { name: 'АН Виктори', phone: '+7 495 123 45 67', shared: true } unless agent

      name = [agent.first_name, agent.last_name].compact_blank.join(' ').strip
      phone = agent.phone.presence
      if phone
        { name: name.presence || 'АН Виктори', phone: phone }
      else
        { name: name.presence || 'АН Виктори', phone: '+7 495 123 45 67', shared: true }
      end
    end

    def self.amenities(p)
      {
        has_balcony:  p.has_balcony,
        has_loggia:   p.has_loggia,
        has_parking:  p.has_parking,
        has_elevator: p.has_elevator,
        has_security: p.has_security,
        has_concierge: p.has_concierge,
        pets_allowed: p.pets_allowed
      }.select { |_, v| v }
    end
  end
end
