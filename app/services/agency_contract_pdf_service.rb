# frozen_string_literal: true

require 'prawn'
require 'rqrcode'

# A7 Phase 3: PDF agency contract render service.
#
# Generates legally-formatted PDF of `ListingConsent` — same content
# that client signed, plus signature metadata (IP, UA, hash, QR-code
# pointing to public verify URL).
#
# Reuses `AuditPdf::Theme` font registration (DejaVu для кириллицы).
#
# Usage:
#   pdf_bytes = AgencyContractPdfService.new(consent).call
#   File.binwrite('/tmp/contract.pdf', pdf_bytes)
#
# Output: ~2-3 pages, A4. Page 1: header + parties + subject + commission +
# terms. Page 2: full agreement text (если не уместилось). Last page:
# signature panel с QR code + verify URL.
class AgencyContractPdfService
  PAGE_MARGIN = 50
  INK         = '1a1a1a'
  MUTED       = '888888'
  ACCENT      = 'c9a063'  # gold для подписной панели

  FONT_PATH       = Rails.root.join('app/assets/fonts/DejaVuSans.ttf').to_s
  FONT_BOLD_PATH  = Rails.root.join('app/assets/fonts/DejaVuSans-Bold.ttf').to_s
  FONT_FAMILY     = 'DejaVu'

  def initialize(consent)
    @consent = consent
    @property = consent.property
    @user = consent.user
  end

  def call
    pdf = Prawn::Document.new(
      page_size: 'A4',
      margin:    PAGE_MARGIN
    )
    register_fonts(pdf)
    pdf.font(FONT_FAMILY)
    pdf.default_leading 2

    render_header(pdf)
    render_status_banner(pdf)
    render_agreement_text(pdf)
    render_signature_panel(pdf)

    pdf.render
  end

  private

  def register_fonts(pdf)
    pdf.font_families.update(
      FONT_FAMILY => {
        normal: FONT_PATH,
        bold:   FONT_BOLD_PATH
      }
    )
  end

  def render_header(pdf)
    pdf.fill_color MUTED
    pdf.font(FONT_FAMILY, style: :bold) do
      pdf.text 'АГЕНТСКИЙ ДОГОВОР', size: 9, character_spacing: 3
    end
    pdf.fill_color INK

    pdf.move_down 4
    pdf.font(FONT_FAMILY, style: :bold) do
      pdf.text "№ #{@property.id}-#{@consent.signed_at.strftime('%Y%m%d')}", size: 22
    end
    pdf.fill_color MUTED
    pdf.text "Версия документа: #{@consent.consent_version}", size: 9
    pdf.text "Подписан: #{@consent.signed_at.strftime('%d.%m.%Y в %H:%M МСК')}", size: 9
    pdf.fill_color INK
    pdf.move_down 18
    pdf.stroke_color MUTED
    pdf.stroke_horizontal_rule
    pdf.move_down 18
  end

  def render_status_banner(pdf)
    if @consent.revoked?
      pdf.fill_color 'b91c1c'
      pdf.font(FONT_FAMILY, style: :bold) do
        pdf.text "⚠ ДОГОВОР ОТОЗВАН #{@consent.revoked_at.strftime('%d.%m.%Y')}", size: 12
      end
      pdf.fill_color INK
      pdf.move_down 18
    elsif !@consent.tamper_check
      pdf.fill_color 'b91c1c'
      pdf.font(FONT_FAMILY, style: :bold) do
        pdf.text '⚠ ЦЕЛОСТНОСТЬ ДОКУМЕНТА НАРУШЕНА', size: 12
      end
      pdf.fill_color INK
      pdf.move_down 18
    end
  end

  def render_agreement_text(pdf)
    pdf.font(FONT_FAMILY, style: :normal) do
      # Preserve newlines из stored consent_text. Prawn text auto-wraps.
      pdf.text @consent.consent_text.to_s, size: 9, leading: 2
    end
    pdf.move_down 24
  end

  def render_signature_panel(pdf)
    # Start panel на same page если хватает места, else new page
    pdf.start_new_page if pdf.cursor < 240

    pdf.stroke_color ACCENT
    pdf.line_width 1.5
    pdf.stroke_horizontal_rule
    pdf.move_down 18

    pdf.fill_color MUTED
    pdf.font(FONT_FAMILY, style: :bold) do
      pdf.text 'ЭЛЕКТРОННАЯ ПОДПИСЬ', size: 8, character_spacing: 3
    end
    pdf.fill_color INK
    pdf.move_down 12

    # Two-column: left = signature data, right = QR code
    left_col_width = pdf.bounds.width - 130
    pdf.bounding_box(
      [0, pdf.cursor],
      width: left_col_width
    ) do
      pdf.font(FONT_FAMILY, style: :normal) do
        pdf.fill_color MUTED
        pdf.text 'ПОДПИСАЛ', size: 7, character_spacing: 2
        pdf.fill_color INK
        pdf.text user_display_name, size: 11
        pdf.move_down 6
        pdf.fill_color MUTED
        pdf.text 'EMAIL', size: 7, character_spacing: 2
        pdf.fill_color INK
        pdf.text @user.email, size: 10
        pdf.move_down 6
        pdf.fill_color MUTED
        pdf.text 'IP АДРЕС', size: 7, character_spacing: 2
        pdf.fill_color INK
        pdf.text @consent.ip_address.to_s, size: 10
        pdf.move_down 6
        pdf.fill_color MUTED
        pdf.text 'ХЕШ ДОКУМЕНТА (SHA-256)', size: 7, character_spacing: 2
        pdf.fill_color INK
        pdf.text @consent.content_hash, size: 7
      end
    end

    # QR code (top-right of signature panel)
    pdf.bounding_box(
      [pdf.bounds.width - 110, pdf.cursor + 110],
      width: 110,
      height: 110
    ) do
      qr_data = qr_code_png
      if qr_data
        pdf.image StringIO.new(qr_data), fit: [100, 100]
        pdf.fill_color MUTED
        pdf.text 'Верификация по QR', size: 7, align: :center
        pdf.fill_color INK
      end
    end

    pdf.move_down 12
    pdf.fill_color MUTED
    pdf.font_size 8 do
      pdf.text "Проверить подлинность: #{verify_url}", size: 7, align: :left
    end
    pdf.fill_color INK
  end

  def user_display_name
    name = [@user.last_name, @user.first_name].compact_blank.join(' ').strip
    name.presence || @user.email
  end

  def qr_code_png
    qr = RQRCode::QRCode.new(verify_url, level: :m)
    qr.as_png(
      size:           300,
      border_modules: 2,
      color:          INK,
      fill:           'FFFFFF'
    ).to_blob
  rescue StandardError => e
    Rails.logger.warn("[AgencyContractPdfService] QR generate failed: #{e.message}")
    nil
  end

  def verify_url
    @verify_url ||= begin
      base = ENV['APP_URL'].presence ||
             (defined?(AgencyInfo) ? AgencyInfo::WEBSITE_URL : 'https://victory62.org')
      "#{base}/verify-contract/#{@consent.token}"
    end
  end
end
