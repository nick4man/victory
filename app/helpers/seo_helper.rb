# frozen_string_literal: true

# Generic SEO helpers — complement to PropertyImageHelper (which handles
# the heavyweight responsive <picture> for Property attachments).
#
# Use this for decorative images, icons, hero illustrations, article
# images, third-party logos — anything where you don't need srcset/webp
# but DO need lazy-loading + async decoding + alt-text rigor.
module SeoHelper
  # Render an <img> with sensible SEO defaults.
  #
  # @param src [String, ActiveStorage::Attachment, ActiveStorage::Variant] image source
  # @param alt [String] required alt text — never empty; never decorative-only
  # @param eager_first [Boolean] true → loading="eager" + fetchpriority="high"
  #   (use only for the single above-the-fold LCP image on a page)
  # @param opts [Hash] passed to image_tag (class:, width:, height:, etc.)
  def image_with_lazy(src, alt:, eager_first: false, **opts)
    image_tag(
      src,
      alt: alt,
      loading: eager_first ? 'eager' : 'lazy',
      decoding: 'async',
      fetchpriority: eager_first ? 'high' : nil,
      **opts.compact
    )
  end
end
