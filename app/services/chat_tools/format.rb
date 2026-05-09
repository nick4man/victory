# frozen_string_literal: true

module ChatTools
  # Map a Property → slim hash the LLM consumes. Used by every tool that
  # returns a list of objects.
  module Format
    module_function

    # @param p [Property]
    # @param extra [Hash] merged on top (e.g. similarity_score)
    def property(p, extra = {})
      {
        id:               p.id,
        slug:             p.slug,
        title:            sanitize_text(p.title),
        property_type:    p.property_type&.slug,
        deal_type:        p.deal_type,
        rooms:            p.rooms,
        area:             p.area&.to_f,
        area_unit:        p.property_type&.slug == 'land' ? 'соток' : 'м²',
        area_display:     area_display(p),
        land_area_m2:     p.respond_to?(:land_area_m2) ? p.land_area_m2&.to_f : nil,
        floor:            p.floor && p.total_floors ? "#{p.floor}/#{p.total_floors}" : nil,
        district:         sanitize_text(p.district),
        metro_station:    sanitize_text(p.metro_station),
        price:            p.price&.to_i,
        price_text:       p.price_formatted,
        condition:        p.condition,
        url:              ChatTools::Url.property_path(p.slug)
      }.compact.merge(extra)
    end

    # Single source of truth for human area phrasing — used by LLM tool output
    # so the model never has to guess units.
    def area_display(p)
      return nil unless p.area
      slug = p.property_type&.slug
      if slug == 'land'
        sotki = (p.area.to_f / 100.0)
        sotki >= 1 ? "#{format_decimal(sotki)} соток" : "#{p.area.to_f.round} м²"
      elsif slug == 'house' && p.respond_to?(:land_area_m2) && p.land_area_m2.to_f.positive?
        "#{p.area.to_f.round} м² на #{format_decimal(p.land_area_m2.to_f / 100.0)} соток"
      else
        "#{p.area.to_f.round} м²"
      end
    end

    def format_decimal(n)
      n = n.to_f
      n == n.round ? n.to_i.to_s : n.round(1).to_s
    end

    # Strip HTML tags / angle brackets from agent-entered fields before they hit the LLM.
    # Defensive: catalog data is mostly clean, but Topnlab is editable by humans.
    def sanitize_text(s)
      return nil if s.nil?
      ActionController::Base.helpers.strip_tags(s.to_s).gsub(/[<>]/, '').strip.presence
    end
  end
end
