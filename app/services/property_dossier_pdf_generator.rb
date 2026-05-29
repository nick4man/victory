# frozen_string_literal: true

require 'prawn'
require 'prawn/table'

# A3 — premium Property dossier PDF. Sotheby's-style brochure для elite-сегмента.
# Generates по одной Property record: cover + gallery + description + agent + CTA.
#
# Reuses AuditPdf::Theme constants (palette, font paths, helpers) — единый
# brand-look между audit-отчётом и property-dossier. Page modules живут в
# `app/services/property_dossier/`.
#
# Locale support: :ru (default) or :en. Wraps render в `I18n.with_locale`.
# Foreign-investor dossier (EN) — Phase 2; пока RU primary.
#
# Premium gate: controller сам проверяет `property.premium?` перед вызовом —
# generator работает для любой Property (для admin / preview).
class PropertyDossierPdfGenerator
  def self.call(property, locale: :ru, rates: nil)
    new(property, locale: locale, rates: rates).render
  end

  def initialize(property, locale: :ru, rates: nil)
    @p      = property
    @locale = (locale || :ru).to_sym
    @rates  = rates || (CurrencyRatesService.call if defined?(CurrencyRatesService))
  end

  def render
    I18n.with_locale(@locale) do
      doc = build_document
      register_fonts(doc)
      doc.font AuditPdf::Theme::FONT_FAMILY

      shared_args   = [doc, @p]
      shared_kwargs = { locale: @locale, rates: @rates }

      PropertyDossier::CoverPage.new(*shared_args, **shared_kwargs).render
      PropertyDossier::GalleryPage.new(*shared_args, **shared_kwargs).render
      PropertyDossier::DescriptionPage.new(*shared_args, **shared_kwargs).render
      PropertyDossier::AgentPage.new(*shared_args, **shared_kwargs).render
      PropertyDossier::CtaPage.new(*shared_args, **shared_kwargs).render

      doc.render
    end
  end

  private

  def build_document
    Prawn::Document.new(
      page_size: 'A4',
      margin: AuditPdf::Theme::PAGE_MARGIN,
      info: {
        Title:    I18n.t('dossier.pdf_meta.title', default: 'Premium property dossier'),
        Author:   I18n.t('dossier.pdf_meta.author', default: AgencyInfo::NAME),
        Subject:  I18n.t('dossier.pdf_meta.subject', default: 'Property brochure'),
        Creator:  'victory62.org',
        Producer: I18n.t('dossier.pdf_meta.producer', default: 'АН Виктори · victory62.org')
      }
    )
  end

  # Mirrors AuditPdfGenerator — same DejaVu font family (Cyrillic-safe +
  # Latin glyphs для EN dossier later).
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
