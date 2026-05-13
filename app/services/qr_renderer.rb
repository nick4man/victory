# frozen_string_literal: true

require 'rqrcode'

# Renders a QR code as PNG bytes for embedding in Prawn PDF reports.
# Used by AuditPdfGenerator + PdfGeneratorService to print scannable codes
# for the Telegram channel + site URL on report covers / signatures.
#
# Pure RubyZER — no native magick deps. ChunkyPNG draws the modules into
# a small PNG which Prawn can embed via `image StringIO.new(bytes)`.
class QrRenderer
  # Render each module as a fixed N×N pixel block instead of asking chunky_png
  # to fit a target output size — that path uses linear interpolation and turns
  # modules anti-aliased gray once Prawn downscales the PNG into 60-90pt of
  # report real estate. With a fixed module_px_size, modules stay solid black
  # and survive the PDF-viewer's bilinear resample.
  ERROR_LEVEL           = :m # 15% redundancy
  DEFAULT_MODULE_PX     = 12
  DEFAULT_BORDER_MODULES = 4 # spec-recommended quiet zone

  def self.png(data, module_px_size: DEFAULT_MODULE_PX)
    new(data, module_px_size: module_px_size).png
  end

  # Scalable SVG variant — used by static channel-QR asset (one-shot via
  # `rake qr:tg`), not at request-time. Default module_size tuned so the
  # img-tag downscale on dark site theme keeps modules visibly solid.
  def self.svg(data, module_size: 12, color: '000000')
    RQRCode::QRCode.new(data.to_s, level: ERROR_LEVEL)
                   .as_svg(viewbox: true, module_size: module_size, color: color,
                           shape_rendering: 'crispEdges')
  rescue StandardError => e
    Rails.logger.warn("[QrRenderer.svg] failed to render '#{data.to_s[0, 40]}': #{e.class} #{e.message}")
    nil
  end

  def initialize(data, module_px_size: DEFAULT_MODULE_PX)
    @data = data.to_s
    @module_px_size = module_px_size.to_i
  end

  def png
    qr = RQRCode::QRCode.new(@data, level: ERROR_LEVEL)
    # 8-char hex with explicit alpha (FF) is REQUIRED — chunky_png parses
    # 6-char '000000' as rgba(0,0,0,0) i.e. transparent black, which renders
    # invisibly against any PDF page background.
    qr.as_png(
      border_modules: DEFAULT_BORDER_MODULES,
      module_px_size: @module_px_size,
      color: '000000FF',
      fill:  'FFFFFFFF'
    ).to_s
  rescue StandardError => e
    Rails.logger.warn("[QrRenderer] failed to render '#{@data.truncate(40)}': #{e.class} #{e.message}")
    nil
  end
end
