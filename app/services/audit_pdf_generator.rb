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
  def self.call(valuation)
    new(valuation).render
  end

  def initialize(valuation)
    @v     = valuation
    @audit = (valuation.evaluation_data || {})['audit'] || {}
    @mc    = (valuation.evaluation_data || {})['monte_carlo'] || {}
  end

  def render
    doc = build_document
    register_fonts(doc)
    doc.font AuditPdf::Theme::FONT_FAMILY

    AuditPdf::CoverPage.new(doc, @v, @audit, @mc).render
    AuditPdf::EiDetailsPage.new(doc, @v, @audit, @mc).render
    AuditPdf::ScenariosPage.new(doc, @v, @audit, @mc).render
    AuditPdf::BankOffersPage.new(doc, @v, @audit, @mc).render
    AuditPdf::GlossaryPage.new(doc, @v, @audit, @mc).render

    doc.render
  end

  private

  def build_document
    Prawn::Document.new(
      page_size: 'A4',
      margin: AuditPdf::Theme::PAGE_MARGIN,
      info: {
        Title:    'Инвестиционный аудит — АН Виктори',
        Author:   'АН Виктори',
        Subject:  'Investment audit report',
        Creator:  'victory62.org',
        Producer: 'АН Виктори · victory62.org'
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
