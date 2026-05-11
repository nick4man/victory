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
