# frozen_string_literal: true

namespace :qr do
  desc 'Regenerate the static @rznvictory Telegram channel QR SVG asset'
  task tg: :environment do
    svg = QrRenderer.svg('https://t.me/rznvictory', module_size: 8, color: '000000')
    abort '[qr:tg] generation failed (rqrcode error)' if svg.blank?

    # Two destinations:
    # - public/  → served as plain static file (current path in views)
    # - app/assets/images/  → available if/when Sprockets asset_path picks it up
    [Rails.public_path.join('tg-rznvictory-qr.svg'),
     Rails.root.join('app/assets/images/tg-rznvictory-qr.svg')].each do |path|
      FileUtils.mkdir_p(path.dirname)
      File.write(path, svg)
      puts "[qr:tg] wrote #{svg.bytesize} bytes → #{path.relative_path_from(Rails.root)}"
    end
  end
end
