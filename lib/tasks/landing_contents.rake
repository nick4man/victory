# frozen_string_literal: true

require 'nokogiri'

namespace :landing_contents do
  # Promote the 20 hand-written ERB partials in app/views/landings/content/
  # into LandingContent rows. After this runs, the admin panel becomes the
  # canonical place to edit district copy; the partials stay on disk as a
  # fallback for slots that don't have a DB row yet.
  #
  # Idempotent: skips slugs that already have a published LandingContent row.
  desc 'Import _sale_kvartira_<slug>.html.erb partials into LandingContent rows'
  task import_partials: :environment do
    partials_dir = Rails.root.join('app/views/landings/content')
    files = Dir[partials_dir.join('_sale_kvartira_*.html.erb')]
    puts "Found #{files.size} partials to import."

    imported = 0
    skipped  = 0

    files.each do |path|
      slug = File.basename(path, '.html.erb').sub(/^_sale_kvartira_/, '')
      next puts("  skip: unknown district slug '#{slug}'") || (skipped += 1) unless RyazanDistricts.name_for(slug)

      existing = LandingContent.find_by(intent: 'sale', type: 'kvartira', district_slug: slug, rooms: nil)
      if existing && existing.published
        skipped += 1
        puts "  skip: #{slug} (already published, id=#{existing.id})"
        next
      end

      blocks, title = parse_partial(path)
      lc = existing || LandingContent.new(intent: 'sale', type: 'kvartira', district_slug: slug, rooms: nil)
      lc.title = title || RyazanDistricts.name_for(slug)
      lc.body_blocks = blocks
      lc.published = true
      lc.save!
      imported += 1
      puts "  imported: #{slug} → #{blocks.size} blocks (id=#{lc.id})"
    end

    puts "\nDone. imported=#{imported}, skipped=#{skipped}, total LandingContent.count=#{LandingContent.count}"
  end

  # @return [Array(Array<Hash>, String)] body_blocks, title
  def parse_partial(path)
    raw = File.read(path)
    doc = Nokogiri::HTML.fragment(raw)
    blocks = []
    title = nil

    doc.children.each do |node|
      next unless node.element?

      case node.name
      when 'h2'
        title ||= node.text.strip
        blocks << { 'kind' => 'heading', 'level' => 2, 'text' => node.text.strip }
      when 'h3'
        blocks << { 'kind' => 'heading', 'level' => 3, 'text' => node.text.strip }
      when 'p'
        text = node.text.strip
        blocks << { 'kind' => 'paragraph', 'text' => text } if text.present?
      when 'details'
        # Group all consecutive <details> into one FAQ block. Here we just
        # collect this <details> into a faq block — adjacent <details> will
        # produce separate faq blocks; we merge them post-pass.
        summary = node.at_css('summary')&.text&.strip
        answer  = node.children.reject { |c| c.name == 'summary' }.map(&:text).join(' ').gsub(/\s+/, ' ').strip
        next if summary.blank?
        if blocks.last&.dig('kind') == 'faq'
          blocks.last['items'] << { 'q' => summary, 'a' => answer }
        else
          blocks << { 'kind' => 'faq', 'items' => [{ 'q' => summary, 'a' => answer }] }
        end
      end
    end

    [blocks, title]
  end
end
