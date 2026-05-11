# frozen_string_literal: true

# Renders Property image attachments as a responsive <picture> with webp+jpeg
# sources and a srcset across three sizes (thumb 400 / card 800 / hero 1920).
#
# Why a <picture> tag instead of <img srcset>:
#   - The <source type="image/webp"> lets the browser pick webp when supported
#     (~40% smaller than jpeg at equivalent quality). Older Safari versions get
#     the <img> fallback automatically.
#   - One <img> with srcset can't switch formats; <picture> can.
#
# Why a helper rather than inline ERB:
#   - We render the same image in 4+ places (card, hero, gallery, JSON-LD).
#   - sizes hints differ per place but srcset+webp logic is identical.
module PropertyImageHelper
  FALLBACK_HERO_URL = 'https://images.unsplash.com/photo-1600585154340-be6161a56a0c?w=1920&q=80'
  FALLBACK_CARD_URL = 'https://images.unsplash.com/photo-1600585154340-be6161a56a0c?w=800&q=80'

  # Render a <picture> element for an Active Storage attachment.
  #
  # @param image [ActiveStorage::Attachment, nil] Property#images member
  # @param alt [String] required alt text — pass property_image_alt(property, idx)
  # @param sizes [String] CSS sizes attribute (e.g. "(min-width: 1024px) 33vw, 100vw")
  # @param priority [Boolean] true → loading="eager" + fetchpriority="high" (LCP slot)
  # @param html_class [String] class for the <img>
  # @param fallback [Symbol] :hero or :card placeholder if image is missing/broken
  def property_picture(image, alt:, sizes: '100vw', priority: false, html_class: nil, fallback: :card)
    return fallback_picture(alt: alt, html_class: html_class, fallback: fallback) unless image.respond_to?(:variant)

    webp_srcset = build_srcset(image, format: :webp)
    jpeg_srcset = build_srcset(image, format: :jpeg)
    img_src     = url_for(image.variant(:card))

    content_tag(:picture) do
      concat tag.source(srcset: webp_srcset, sizes: sizes, type: 'image/webp')
      concat image_tag(img_src,
                       alt: alt,
                       srcset: jpeg_srcset,
                       sizes: sizes,
                       loading: priority ? 'eager' : 'lazy',
                       decoding: 'async',
                       fetchpriority: priority ? 'high' : nil,
                       class: html_class)
    end
  rescue StandardError => e
    Rails.logger.warn("[PropertyImageHelper] picture render failed: #{e.class} #{e.message}")
    fallback_picture(alt: alt, html_class: html_class, fallback: fallback)
  end

  # URL for a single variant — used by JSON-LD and og:image, both of which
  # need ABSOLUTE URLs (VK/Telegram/Yandex social-share crawlers don't
  # follow relative paths). Hero variant gives ≥1200px which is the
  # rich-result eligibility threshold for both Google and Yandex.
  def property_image_url(image, variant: :hero)
    return FALLBACK_HERO_URL unless image.respond_to?(:variant)
    Rails.application.routes.url_helpers.rails_representation_url(
      image.variant(variant),
      host: request.host_with_port,
      protocol: request.protocol.sub('://', '')
    )
  rescue StandardError
    FALLBACK_HERO_URL
  end

  private

  def build_srcset(image, format:)
    thumb_v = format == :webp ? :thumb_webp : :thumb
    card_v  = format == :webp ? :card_webp  : :card
    hero_v  = format == :webp ? :hero_webp  : :hero
    [
      "#{url_for(image.variant(thumb_v))} 400w",
      "#{url_for(image.variant(card_v))} 800w",
      "#{url_for(image.variant(hero_v))} 1920w"
    ].join(', ')
  end

  def fallback_picture(alt:, html_class:, fallback:)
    src = fallback == :hero ? FALLBACK_HERO_URL : FALLBACK_CARD_URL
    image_tag(src, alt: alt, class: html_class, loading: 'lazy', decoding: 'async')
  end
end
