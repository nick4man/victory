# frozen_string_literal: true

require 'prawn'
require 'prawn/table'

# Orchestrates a multi-page premium PDF report for a completed
# investment audit. Page modules live in `app/services/audit_pdf/` —
# each renders one logical page and shares look via `AuditPdf::Theme`.
#
# Visual design: light "luxury real estate brochure" — cream paper,
# black ink, gold accent rule, generous whitespace + Sotheby's-style
# cover page. Engine has its own WeasyPrint generator (`pdf_branded.py`)
# but no HTTP endpoint exposes it, so we render server-side from the
# stored `evaluation_data`.
class AuditPdfGenerator
  def self.call(valuation, locale: nil)
    new(valuation, locale: locale).render
  end

  # @param valuation [PropertyValuation] completed investment audit
  # @param locale [Symbol, nil] :ru (default) | :en. Если nil — читаем
  #   valuation.metadata['audit_locale'] (Foreign::AuditsController туда
  #   кладёт 'en'); fallback на I18n.default_locale.
  def initialize(valuation, locale: nil)
    @v       = valuation
    @audit   = (valuation.evaluation_data || {})['audit'] || {}
    @mc      = (valuation.evaluation_data || {})['monte_carlo'] || {}
    @locale  = (locale || valuation.metadata&.[]('audit_locale') || I18n.default_locale).to_sym
    @rates   = valuation.metadata&.[]('exchange_rates') || CurrencyRatesService.call
  end

  def render
    # Wraps ENTIRE render в I18n.with_locale — все page modules вызывают
    # I18n.t('audit.…') и автоматически получают RU или EN.
    I18n.with_locale(@locale) do
      doc = build_document
      register_fonts(doc)
      doc.font AuditPdf::Theme::FONT_FAMILY

      shared_args = [doc, @v, @audit, @mc]
      shared_kwargs = { locale: @locale, rates: @rates }

      AuditPdf::CoverPage.new(*shared_args, **shared_kwargs).render
      AuditPdf::EiDetailsPage.new(*shared_args, **shared_kwargs).render
      AuditPdf::ScenariosPage.new(*shared_args, **shared_kwargs).render
      AuditPdf::BankOffersPage.new(*shared_args, **shared_kwargs).render

      # Foreign audit only — visa/residency chapter + conversion table.
      # Inserted перед glossary чтобы closing pages (glossary + signature
      # footer) оставались последними.
      if @locale == :en
        if @v.metadata&.[]('visa_chapter_en').present?
          AuditPdf::VisaResidencyPage.new(*shared_args, **shared_kwargs).render
        end
        AuditPdf::ConversionTablePage.new(*shared_args, **shared_kwargs).render
      end

      AuditPdf::GlossaryPage.new(*shared_args, **shared_kwargs).render

      doc.render
    end
  end

  private

  def build_document
    Prawn::Document.new(
      page_size: 'A4',
      margin: AuditPdf::Theme::PAGE_MARGIN,
      info: {
        Title:    I18n.t('audit.pdf_meta.title'),
        Author:   I18n.t('audit.pdf_meta.author'),
        Subject:  I18n.t('audit.pdf_meta.subject'),
        Creator:  'victory62.org',
        Producer: I18n.t('audit.pdf_meta.producer')
      }
    )
  end

  def register_fonts(doc)
    doc.font_families.update(
      AuditPdf::Theme::FONT_FAMILY => {
        normal:      AuditPdf::Theme::FONT_PATH,
        bold:        AuditPdf::Theme::FONT_BOLD_PATH,
        italic:      AuditPdf::Theme::FONT_PATH,
        bold_italic: AuditPdf::Theme::FONT_BOLD_PATH
      }
    )
  end
end
