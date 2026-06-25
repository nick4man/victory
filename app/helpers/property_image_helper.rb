# frozen_string_literal: true

# Renders Property image attachments as a responsive <picture> with avif+webp+jpeg
# sources and a srcset across three sizes (thumb 400 / card 800 / hero 1920).
#
# Why a <picture> tag instead of <img srcset>:
#   - Browser picks first <source> with supported type. Order matters: AVIF
#     first (50% smaller than jpeg, Chrome 85+/Firefox 93+/Safari 16.4+),
#     WebP second (broader support, ~30% smaller), <img> jpeg fallback for
#     Safari ≤16, social crawlers, RSS readers.
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

    avif_srcset = build_srcset(image, format: :avif)
    webp_srcset = build_srcset(image, format: :webp)
    jpeg_srcset = build_srcset(image, format: :jpeg)
    img_src     = url_for(image.variant(:card))

    # AVIF source first — browser выбирает первый supported type. Chrome 85+,
    # Firefox 93+, Safari 16.4+ возьмут AVIF; всё ниже — WebP; всё ниже
    # WebP — JPEG из <img>. Sizes attribute identical для всех source'ов.
    content_tag(:picture) do
      concat tag.source(srcset: avif_srcset, sizes: sizes, type: 'image/avif')
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

  # Render TWO <link rel=preload> for LCP hero — AVIF first, WebP second.
  # Each browser triggers only one preload (matching its supported type),
  # so no wasted bytes. Modern `imagesrcset`/`imagesizes` attrs позволяют
  # preload respect responsive srcset (browser picks the right size без
  # отдельного preload-per-breakpoint).
  #
  # Использование: в <head> перед закрытием — раннее чтение URL'ов парсера,
  # не дожидаясь body. Экономит ~200-300ms LCP на cold visits (Yandex
  # MatrixNet взвешивает LCP сильно для mobile-first ranking).
  def property_hero_preloads(image, sizes: '100vw')
    return '' unless image.respond_to?(:variant)

    avif_srcset = build_srcset(image, format: :avif)
    webp_srcset = build_srcset(image, format: :webp)

    safe_join([
      tag.link(rel: 'preload', as: 'image', imagesrcset: avif_srcset,
               imagesizes: sizes, type: 'image/avif', fetchpriority: 'high'),
      tag.link(rel: 'preload', as: 'image', imagesrcset: webp_srcset,
               imagesizes: sizes, type: 'image/webp', fetchpriority: 'high')
    ])
  rescue StandardError => e
    Rails.logger.warn("[PropertyImageHelper] hero preload failed: #{e.class} #{e.message}")
    ''
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

  # format → variant suffix mapping. :jpeg использует базовые variants без
  # суффикса (legacy default), :webp/:avif — соответствующие variants из
  # Property модели. Suffix-based чтобы не плодить hashes; легко добавить
  # новый формат (jxl, ...) когда libvips подтянет support.
  VARIANT_SUFFIX = { jpeg: '', webp: '_webp', avif: '_avif' }.freeze

  def build_srcset(image, format:)
    suffix  = VARIANT_SUFFIX.fetch(format)
    thumb_v = :"thumb#{suffix}"
    card_v  = :"card#{suffix}"
    hero_v  = :"hero#{suffix}"
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
