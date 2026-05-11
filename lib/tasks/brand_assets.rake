# frozen_string_literal: true

# Generates brand placeholder assets (PWA icons + favicon + OG default image)
# via libvips. Designed for bootstrap — once a designer ships real artwork
# these should be replaced by hand-tuned PNGs in public/.
#
# What's produced (all in public/):
#   icon-192.png             — PWA primary
#   icon-512.png             — PWA primary
#   icon-maskable-192.png    — PWA maskable variant with 20% safe zone
#   icon-maskable-512.png    — PWA maskable variant with 20% safe zone
#   favicon-32.png           — browser tab
#   apple-touch-icon.png     — iOS home screen (180×180)
#   og-default.jpg           — social-share preview fallback (1200×630)
namespace :assets do
  desc 'Generate brand placeholder PNG icons + OG default via libvips'
  task generate_brand_icons: :environment do
    require 'vips'

    out = Rails.root.join('public')
    FileUtils.mkdir_p(out)

    BG_COLOR    = [10, 10, 10].freeze unless defined?(BG_COLOR)
    TEXT_FONT   = 'DejaVu Sans Bold'.freeze unless defined?(TEXT_FONT)
    MONOGRAM    = 'В'

    # Square monogram icons. `padding` carves out the maskable safe zone
    # (Android crops up to 20% of each edge into circular/squircle masks).
    [
      { size: 192,  padding: 0,  name: 'icon-192.png' },
      { size: 512,  padding: 0,  name: 'icon-512.png' },
      { size: 192,  padding: 38, name: 'icon-maskable-192.png' },
      { size: 512,  padding: 102, name: 'icon-maskable-512.png' },
      { size: 32,   padding: 0,  name: 'favicon-32.png' },
      { size: 180,  padding: 0,  name: 'apple-touch-icon.png' }
    ].each do |spec|
      generate_monogram_icon(out.join(spec[:name]), size: spec[:size], padding: spec[:padding], text: MONOGRAM)
      puts "  generated #{spec[:name]}"
    end

    generate_og_default(out.join('og-default.jpg'))
    puts '  generated og-default.jpg'
    puts ''
    puts 'Done. Replace these with designer artwork before public launch.'
  end

  # @api private
  # Renders a square icon: dark background + centered white text.
  def generate_monogram_icon(output, size:, padding: 0, text: 'В')
    bg_color = [10, 10, 10]

    bg = Vips::Image.black(size, size)
                    .new_from_image(bg_color)
                    .copy(interpretation: :srgb)
                    .cast(:uchar)

    inner = size - 2 * padding
    font_size = (inner * 0.62).to_i
    text_mask = Vips::Image.text(text, font: "DejaVu Sans Bold #{font_size}", dpi: 96)

    # Single-band alpha mask → RGBA where RGB = white, A = mask.
    white_const = text_mask.linear(0, 255)
    rgba_text = white_const.bandjoin([white_const, white_const, text_mask])
                            .copy(interpretation: :srgb)

    x = (size - text_mask.width) / 2
    y = (size - text_mask.height) / 2
    bg.composite2(rgba_text, :over, x: x, y: y).write_to_file(output.to_s)
  end

  # @api private
  # Renders the 1200×630 OG default with two-line text: brand + tagline.
  def generate_og_default(output)
    w = 1200
    h = 630
    bg_color = [10, 10, 10]

    bg = Vips::Image.black(w, h)
                    .new_from_image(bg_color)
                    .copy(interpretation: :srgb)
                    .cast(:uchar)

    title  = Vips::Image.text('АН «Виктори»', font: 'DejaVu Sans Bold 110', dpi: 96)
    tag    = Vips::Image.text('АГЕНТСТВО НЕДВИЖИМОСТИ • РЯЗАНЬ',
                              font: 'DejaVu Sans 40', dpi: 96, spacing: 8)

    title_rgba = mask_to_white_rgba(title)
    tag_rgba   = mask_to_white_rgba(tag)

    title_x = (w - title.width) / 2
    title_y = (h - title.height - tag.height - 40) / 2
    tag_x   = (w - tag.width) / 2
    tag_y   = title_y + title.height + 40

    bg.composite2(title_rgba, :over, x: title_x, y: title_y)
      .composite2(tag_rgba,   :over, x: tag_x,   y: tag_y)
      .write_to_file(output.to_s, Q: 88)
  end

  # @api private
  def mask_to_white_rgba(mask)
    white = mask.linear(0, 255)
    white.bandjoin([white, white, mask]).copy(interpretation: :srgb)
  end
end
