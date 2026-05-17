# frozen_string_literal: true

module AuditPdf
  # Page 4 — risks, assumptions, glossary, contact. i18n: audit.glossary.*
  class GlossaryPage
    include Theme::Helpers

    def initialize(doc, valuation, audit, _monte_carlo, locale: I18n.locale, rates: nil)
      @doc = doc
      @v = valuation
      @audit = audit || {}
      @locale = locale
      @rates = rates
    end

    def render
      @doc.start_new_page
      paint_paper
      page_header
      risks_assumptions
      glossary
      contact_footer
      page_footer
    end

    private

    def paint_paper
      @doc.canvas do
        @doc.fill_color Theme::PAPER
        @doc.fill_rectangle [0, @doc.bounds.height], @doc.bounds.width, @doc.bounds.height
      end
      @doc.fill_color Theme::INK
    end

    def page_header
      @doc.font(Theme::FONT_FAMILY, style: :bold) do
        @doc.text I18n.t('audit.glossary.page_title').upcase, size: 18
      end
      @doc.move_down 6
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 18
    end

    def risks_assumptions
      risks = Array(@audit['risks']).compact_blank
      assumptions = Array(@audit['assumptions']).compact_blank

      if risks.any?
        section_label(I18n.t('audit.glossary.risks_header').upcase)
        @doc.move_down 4
        risks.each do |r|
          @doc.text "<color rgb='#{Theme::ACCENT_GOLD}'>▸</color>  #{r}",
                    size: 10.5, inline_format: true, leading: 2
          @doc.move_down 4
        end
        @doc.move_down 10
      end

      if assumptions.any?
        section_label(I18n.t('audit.glossary.assumptions_header').upcase)
        @doc.move_down 4
        @doc.fill_color Theme::INK_SOFT
        assumptions.each do |a|
          @doc.text "·  #{a}", size: 9, leading: 2
          @doc.move_down 2
        end
        @doc.fill_color Theme::INK
        @doc.move_down 14
      end
    end

    def glossary
      section_label(I18n.t('audit.glossary.glossary_header').upcase)
      @doc.move_down 4

      entries = [
        [I18n.t('audit.glossary.terms.efficiency_index.term'),
         I18n.t('audit.glossary.terms.efficiency_index.body')],
        [I18n.t('audit.glossary.terms.monte_carlo.term'),
         I18n.t('audit.glossary.terms.monte_carlo.body')],
        [I18n.t('audit.glossary.terms.buy_probability.term'),
         I18n.t('audit.glossary.terms.buy_probability.body')],
        [I18n.t('audit.glossary.terms.market_scenarios.term'),
         I18n.t('audit.glossary.terms.market_scenarios.body')],
        [I18n.t('audit.glossary.terms.strategies.term'),
         I18n.t('audit.glossary.terms.strategies.body')]
      ]

      entries.each do |term, body|
        @doc.font(Theme::FONT_FAMILY, style: :bold) do
          @doc.text term, size: 10
        end
        @doc.move_down 2
        @doc.fill_color Theme::INK_SOFT
        @doc.font(Theme::FONT_FAMILY, style: :normal) do
          @doc.text body, size: 9, leading: 2, inline_format: true
        end
        @doc.fill_color Theme::INK
        @doc.move_down 10
      end
    end

    def contact_footer
      @doc.move_down 14
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 0.6
      @doc.stroke_horizontal_rule
      @doc.move_down 10

      @doc.font(Theme::FONT_FAMILY, style: :bold) do
        @doc.text I18n.t('audit.glossary.contact_header'), size: 9, character_spacing: 3
      end
      @doc.move_down 6
      contact_lines = [
        AgencyInfo::PHONE_PRIMARY,
        AgencyInfo::PHONE_BACKUP,
        AgencyInfo::EMAIL,
        "#{AgencyInfo::ADDRESS_CITY}, #{AgencyInfo::ADDRESS_STREET}"
      ]
      contact_lines.each do |line|
        @doc.text line, size: 10
        @doc.move_down 2
      end
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color Theme::MUTED
      url = AgencyInfo::WEBSITE_URL
      @doc.text "#{I18n.t('audit.page_footer', page: 4, report: @v.report_label)}  ·  #{url}", size: 7, align: :center
      @doc.fill_color Theme::INK
    end
  end
end
