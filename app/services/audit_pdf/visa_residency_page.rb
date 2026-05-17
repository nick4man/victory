# frozen_string_literal: true

module AuditPdf
  # B2 Track 3 — visa/residency/tax chapter for foreign audit PDF.
  # Content cached в `valuation.metadata['visa_chapter_en']` (LLM-generated
  # via VisaResidencyContentGenerator). Если кэша нет — рендерим static
  # fallback из en.yml. i18n: audit.visa.*
  #
  # Page structure:
  #   - Header (audit.visa.page_title)
  #   - Investment-based residency section
  #   - Tax obligations section
  #   - Residency pathways section
  #   - Legal disclaimer footer
  class VisaResidencyPage
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
      render_sections
      legal_disclaimer
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
        @doc.text I18n.t('audit.visa.page_title').upcase, size: 18
      end
      @doc.move_down 6
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 18
    end

    def render_sections
      content = visa_content
      if content.blank? || content['investment_visa'].blank?
        # LLM не сработал — fallback статический текст
        @doc.fill_color Theme::INK_SOFT
        @doc.text I18n.t('audit.visa.generation_failed_fallback'),
                  size: 11, leading: 3
        @doc.fill_color Theme::INK
        @doc.move_down 14
        return
      end

      render_section(I18n.t('audit.visa.investment_visa_header'), content['investment_visa'])
      render_section(I18n.t('audit.visa.tax_obligations_header'), content['tax_obligations'])
      if content['residency_pathways'].present?
        render_section(I18n.t('audit.visa.residency_pathways_header'), content['residency_pathways'])
      end
    end

    def render_section(header, body)
      return if body.to_s.strip.empty?

      section_label(header.to_s.upcase)
      @doc.move_down 4
      @doc.fill_color Theme::INK_SOFT
      @doc.font(Theme::FONT_FAMILY, style: :normal) do
        @doc.text body.to_s.strip, size: 10.5, leading: 3, align: :justify
      end
      @doc.fill_color Theme::INK
      @doc.move_down 14
    end

    def legal_disclaimer
      @doc.move_down 6
      @doc.stroke_color Theme::HAIRLINE
      @doc.line_width 0.5
      @doc.stroke_horizontal_rule
      @doc.move_down 10

      @doc.font(Theme::FONT_FAMILY, style: :bold) do
        @doc.fill_color Theme::INK
        @doc.text I18n.t('audit.visa.legal_disclaimer_header').upcase,
                  size: 8, character_spacing: 3
      end
      @doc.move_down 4

      disclaimer = visa_content&.[]('disclaimer').presence ||
                   I18n.t('audit.visa.legal_disclaimer_default')
      @doc.fill_color Theme::MUTED
      @doc.font(Theme::FONT_FAMILY, style: :italic) do
        @doc.text disclaimer, size: 8, leading: 2, align: :justify
      end
      @doc.fill_color Theme::INK
    end

    def visa_content
      @visa_content ||= @v.metadata&.[]('visa_chapter_en')
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color Theme::MUTED
      @doc.text I18n.t('audit.page_footer', page: 7, report: @v.report_label),
                size: 7, align: :center
      @doc.fill_color Theme::INK
    end
  end
end
