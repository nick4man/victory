# frozen_string_literal: true

# Renders an accessible FAQ section with paired Schema.org FAQPage JSON-LD.
#
# Why bundle the two: <details>/<summary> markup is what users see, but Yandex
# and Google both surface FAQ rich snippets in SERP only when the QA pairs are
# also declared as FAQPage > Question > Answer. Emitting them in lockstep
# means the two can never drift out of sync.
module FaqHelper
  # Renders the full FAQ block: visible accordion + JSON-LD script.
  #
  # @param pairs [Array<Array(String, String)>] e.g. [['Q?', 'A.'], ...]
  # @param heading [String, nil] optional eyebrow above the list
  # @param html_id [String, nil] anchor id for the section (deep-linking)
  def faq_section(pairs, heading: nil, html_id: nil)
    return if pairs.blank?

    safe_join([
      faq_jsonld(pairs),
      content_tag(:section, id: html_id, class: 'faq-section') do
        safe_join([
          (heading.present? ? content_tag(:p, heading, class: 'text-sm tracking-[0.4em] text-muted-foreground mb-6 uppercase') : ''.html_safe),
          content_tag(:div, class: 'flex flex-col') do
            safe_join(pairs.each_with_index.map { |(q, a), i|
              border_b = (i == pairs.length - 1 ? ' border-b' : '')
              content_tag(:details, class: "group border-t border-border#{border_b}") do
                safe_join([
                  content_tag(:summary, class: 'flex items-center justify-between py-6 cursor-pointer list-none') do
                    safe_join([
                      content_tag(:span, q, class: 'text-base tracking-wider text-foreground pr-8'),
                      tag.svg(class: 'w-5 h-5 text-muted-foreground group-open:rotate-45 transition-transform shrink-0',
                              viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '2') do
                        tag.path(d: 'M12 5v14M5 12h14')
                      end
                    ])
                  end,
                  content_tag(:p, a, class: 'pb-6 text-sm text-muted-foreground leading-relaxed pr-8')
                ])
              end
            })
          end
        ])
      end
    ])
  end

  # Scans an HTML fragment for <details><summary>Q</summary>A</details> blocks
  # and returns [[q, a], ...] pairs suitable for `faq_jsonld`. Used by SEO
  # landing pages where the partial author writes FAQ as plain HTML — letting
  # them keep the visible markup hand-written while still emitting matching
  # FAQPage structured data.
  def faq_pairs_from_html(html_fragment)
    return [] if html_fragment.blank?
    doc = Nokogiri::HTML.fragment(html_fragment)
    doc.css('details').filter_map do |d|
      summary = d.at_css('summary')&.content&.strip
      next nil if summary.blank?
      # Answer = everything inside <details> except the <summary> itself.
      answer_html = d.children.reject { |c| c.name == 'summary' }.map(&:to_s).join
      answer_text = Nokogiri::HTML.fragment(answer_html).content.gsub(/\s+/, ' ').strip
      next nil if answer_text.blank?
      [summary, answer_text]
    end
  end

  # Emits just the JSON-LD FAQPage script. Use when the visible FAQ markup
  # already exists in the template and you only need the structured-data hook.
  #
  # @param pairs [Array<Array(String, String)>] question/answer pairs
  def faq_jsonld(pairs)
    return ''.html_safe if pairs.blank?

    content_tag(:script, type: 'application/ld+json') do
      raw({
        '@context' => 'https://schema.org',
        '@type' => 'FAQPage',
        'mainEntity' => pairs.map { |q, a|
          {
            '@type' => 'Question',
            'name' => q.to_s,
            'acceptedAnswer' => { '@type' => 'Answer', 'text' => a.to_s }
          }
        }
      }.to_json)
    end
  end
end
