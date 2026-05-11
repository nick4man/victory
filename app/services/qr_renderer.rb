# frozen_string_literal: true

require 'rqrcode'

# Renders a QR code as PNG bytes for embedding in Prawn PDF reports.
# Used by AuditPdfGenerator + PdfGeneratorService to print scannable codes
# for the Telegram channel + site URL on report covers / signatures.
#
# Pure RubyZER — no native magick deps. ChunkyPNG draws the modules into
# a small PNG which Prawn can embed via `image StringIO.new(bytes)`.
class QrRenderer
  DEFAULT_SIZE_PX = 240
  ERROR_LEVEL     = :m # 15% redundancy — good balance for prints/scans

  def self.png(data, size: DEFAULT_SIZE_PX)
    new(data, size: size).png
  end

  # Scalable SVG variant — used by static channel-QR asset (one-shot via
  # `rake qr:tg`), not at request-time. Inline-friendly; no chunky_png
  # native deps. Default module_size + color tuned for embedding inside
  # a white card on the dark site theme.
  def self.svg(data, module_size: 6, color: '000000')
    RQRCode::QRCode.new(data.to_s, level: ERROR_LEVEL)
                   .as_svg(viewbox: true, module_size: module_size, color: color,
                           shape_rendering: 'crispEdges')
  rescue StandardError => e
    Rails.logger.warn("[QrRenderer.svg] failed to render '#{data.to_s[0, 40]}': #{e.class} #{e.message}")
    nil
  end

  def initialize(data, size: DEFAULT_SIZE_PX)
    @data = data.to_s
    @size = size.to_i
  end

  def png
    qr = RQRCode::QRCode.new(@data, level: ERROR_LEVEL)
    qr.as_png(
      size: @size,
      border_modules: 2,
      color: '000000',
      fill:  'FFFFFF',
      module_px_size: nil
    ).to_s
  rescue StandardError => e
    Rails.logger.warn("[QrRenderer] failed to render '#{@data.truncate(40)}': #{e.class} #{e.message}")
    nil
  end
end
