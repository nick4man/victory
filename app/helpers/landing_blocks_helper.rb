# frozen_string_literal: true

# Renders a single LandingContent body block (the JSONB-stored unit of
# editorial content) to safe HTML. Block shape is a Hash with a `kind`
# discriminator + kind-specific fields — see LandingContent::BLOCK_KINDS.
#
# Used by:
#   - LandingContent#render_html (cache-on-save, displayed on /kupit/*)
#   - Admin::LandingContents preview (live re-render in the editor)
#
# All user-supplied strings pass through `h(...)` — never trust admin
# input as html_safe. Only the wrapper tag structure is trusted.
module LandingBlocksHelper
  KIND_RENDERERS = {
    'heading'   => :render_heading_block,
    'paragraph' => :render_paragraph_block,
    'quote'     => :render_quote_block,
    'link'      => :render_link_block,
    'image'     => :render_image_block,
    'list'      => :render_list_block,
    'faq'       => :render_faq_block
  }.freeze

  def render_landing_block(block)
    return ''.html_safe unless block.is_a?(Hash)

    kind = (block['kind'] || block[:kind]).to_s
    method_name = KIND_RENDERERS[kind]
    return ''.html_safe unless method_name

    send(method_name, block.with_indifferent_access)
  rescue StandardError => e
    Rails.logger.warn("[LandingBlocksHelper] render failed for kind=#{kind}: #{e.message}")
    ''.html_safe
  end

  def render_landing_blocks(blocks)
    return ''.html_safe unless blocks.is_a?(Array)

    safe_join(blocks.map { |b| render_landing_block(b) })
  end

  # Flat-text projection used for the chatbot tool context. We drop visual
  # formatting and emit one paragraph per logical block so the LLM can read
  # the content without HTML noise.
  def landing_blocks_to_plain(blocks)
    return '' unless blocks.is_a?(Array)

    blocks.filter_map { |b| block_to_plain(b.with_indifferent_access) }
          .reject(&:blank?)
          .join("\n\n")
  end

  private

  def render_heading_block(b)
    level = b[:level].to_i.between?(2, 3) ? b[:level].to_i : 2
    content_tag("h#{level}", b[:text].to_s)
  end

  def render_paragraph_block(b)
    content_tag(:p, b[:text].to_s)
  end

  def render_quote_block(b)
    content_tag(:blockquote, class: 'border-l-2 border-border pl-4 italic') do
      pieces = [content_tag(:p, b[:text].to_s)]
      pieces << content_tag(:cite, "— #{b[:author]}".html_safe, class: 'text-sm opacity-70') if b[:author].present?
      safe_join(pieces)
    end
  end

  def render_link_block(b)
    return ''.html_safe if b[:url].blank?

    link_to(b[:text].presence || b[:url], b[:url],
            target: '_blank', rel: 'noopener nofollow',
            class: 'underline hover:no-underline')
  end

  def render_image_block(b)
    return ''.html_safe if b[:signed_id].blank?

    blob = ActiveStorage::Blob.find_signed(b[:signed_id]) rescue nil
    return ''.html_safe unless blob

    content_tag(:figure, class: 'my-6') do
      pieces = [image_tag(rails_blob_path(blob, disposition: 'inline'),
                          alt: b[:alt].to_s,
                          loading: 'lazy',
                          class: 'w-full h-auto')]
      pieces << content_tag(:figcaption, b[:caption].to_s, class: 'text-xs opacity-70 mt-2') if b[:caption].present?
      safe_join(pieces)
    end
  end

  def render_list_block(b)
    tag_name = b[:style].to_s == 'ol' ? :ol : :ul
    items = Array(b[:items]).reject(&:blank?)
    return ''.html_safe if items.empty?

    content_tag(tag_name) do
      safe_join(items.map { |item| content_tag(:li, item.to_s) })
    end
  end

  # FAQ — emits the same <details><summary>Q</summary><p>A</p></details>
  # shape the existing FAQ partials use, so FaqHelper.faq_pairs_from_html
  # picks them up for FAQPage JSON-LD without changes.
  def render_faq_block(b)
    items = Array(b[:items]).reject { |pair| pair.is_a?(Hash) && (pair['q'].blank? || pair['a'].blank?) }
    return ''.html_safe if items.empty?

    safe_join(items.map { |pair|
      pair_h = pair.with_indifferent_access
      content_tag(:details) do
        safe_join([
          content_tag(:summary, pair_h[:q].to_s),
          content_tag(:p, pair_h[:a].to_s)
        ])
      end
    })
  end

  def block_to_plain(b)
    case b[:kind].to_s
    when 'heading', 'paragraph' then b[:text].to_s.strip
    when 'quote'                then [b[:text], b[:author] && "— #{b[:author]}"].compact.join(' ').strip
    when 'link'                 then "#{b[:text]} (#{b[:url]})".strip
    when 'image'                then [b[:alt], b[:caption]].compact_blank.join(' — ').strip
    when 'list'                 then Array(b[:items]).compact_blank.map { |i| "• #{i}" }.join("\n")
    when 'faq'
      Array(b[:items]).filter_map { |p|
        ph = p.is_a?(Hash) ? p.with_indifferent_access : nil
        next nil unless ph && ph[:q].present?
        "Q: #{ph[:q]}\nA: #{ph[:a]}"
      }.join("\n\n")
    else nil
    end
  end
end
