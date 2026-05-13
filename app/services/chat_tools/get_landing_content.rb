# frozen_string_literal: true

module ChatTools
  # Returns the admin-curated SEO text for a Ryazan district (or any
  # other landing slot). Use this when the user asks about a district's
  # housing stock, infrastructure, transport, prices — anything the
  # editorial copy in /kupit/... covers.
  #
  # Falls through to the ERB partials in `app/views/landings/content/` for
  # districts that haven't been promoted into the DB yet, so the bot
  # always has something to ground its answer in.
  module GetLandingContent
    def self.schema
      {
        type: 'function',
        function: {
          name: 'get_landing_content',
          description: 'Экспертный SEO-текст по району Рязани (жилфонд, инфраструктура, транспорт, цены, FAQ). ' \
                       'Использовать когда пользователь спрашивает про конкретный район.',
          parameters: {
            type: 'object',
            properties: {
              district_slug: {
                type: 'string',
                description: "Slug района на латинице. Допустимые: #{RyazanDistricts.all_micro_slugs.join(', ')}"
              },
              type: {
                type: 'string',
                enum: %w[kvartira dom uchastok komnata kommercheskaya],
                description: "Тип недвижимости (по умолчанию 'kvartira')"
              }
            },
            required: %w[district_slug],
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args)
      slug = args[:district_slug].to_s
      type = (args[:type].presence || 'kvartira').to_s

      district_name = RyazanDistricts.name_for(slug)
      return { found: false, error: 'unknown_district', district_slug: slug } unless district_name

      lc = LandingContent.for_landing(intent: 'sale', type: type, district_slug: slug, rooms: nil)
                         .published.first

      if lc
        {
          found: true,
          source: 'db',
          district: district_name,
          district_slug: slug,
          type: type,
          title: lc.title,
          meta_description: lc.meta_description,
          body: lc.body_plain.to_s.truncate(2000),
          public_url: lc.public_path
        }
      else
        fallback = fallback_from_partial(slug, type)
        fallback ? fallback.merge(found: true, source: 'partial', district: district_name, district_slug: slug, type: type)
                 : { found: false, error: 'no_content', district_slug: slug, district: district_name }
      end
    end

    # Read the ERB partial as a plain file, strip ERB tags + HTML, return
    # the visible text. We don't `render` it because rendering needs the
    # full view stack; the partials are pure HTML anyway.
    def self.fallback_from_partial(slug, type)
      path = Rails.root.join('app/views/landings/content', "_sale_#{type}_#{slug}.html.erb")
      return nil unless File.exist?(path)

      raw = File.read(path)
      # Strip ERB tags first, then HTML tags.
      stripped = raw.gsub(/<%[\s\S]*?%>/, '').gsub(/<[^>]+>/, ' ').squeeze(' ').strip
      title = raw[/<h2[^>]*>([^<]+)<\/h2>/, 1]&.strip
      {
        title: title || slug.titleize,
        body: stripped.truncate(2000),
        public_url: "/kupit/#{type}/rayon/#{slug}"
      }
    end
  end
end
