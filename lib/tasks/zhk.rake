# frozen_string_literal: true

# A2 — справочник ЖК (08.08.26).
namespace :zhk do
  desc 'Засеять стартовый справочник ЖК (идемпотентно)'
  task seed: :environment do
    load Rails.root.join('db/seeds/residential_complexes.rb')
  end

  desc 'Показать покрытие справочника: контент / фото / объекты'
  task coverage: :environment do
    # Критерии — из Zhk::Coverage, общего с админкой: иначе консоль и
    # экран разъедутся в оценке готовности.
    photos = Zhk::Coverage.photo_counts_by_slug
    listings = Property.on_site.where.not(residential_complex_id: nil)
                       .group(:residential_complex_id).count

    ResidentialComplex.unscoped.not_deleted.order(:name).each do |c|
      marks = Zhk::Coverage.marks_for(
        c,
        listings_count: listings[c.id].to_i,
        photos_count:   photos[c.slug].to_i
      )
      puts format('%-34s %-22s %s', c.name, c.district_slug.to_s, marks.presence&.join(', ') || 'готов')
    end

    dupes = Zhk::Coverage.duplicate_first_paragraphs
    return if dupes.empty?

    puts "\n⚠ совпадает первый абзац (дубли контента — риск для программного SEO):"
    dupes.each_value { |names| puts "  #{names.join(' / ')}" }
  end

  desc 'Подсказать объекты для привязки к ЖК: rake "zhk:suggest[legenda]"'
  task :suggest, %i[slug strategy] => :environment do |_t, args|
    complex = ResidentialComplex.unscoped.friendly.find(args[:slug])
    result = Zhk::AttachmentSuggester.call(complex, strategy: args[:strategy])

    puts "#{complex.display_name} — стратегия: #{result.strategy}, непривязанных в городе: #{result.pool_size}"
    result.notes.each { |n| puts "  ! #{n}" }

    # Read-only: ничего не пишет, привязка — только руками через админку.
    result.candidates.limit(50).each do |p|
      puts format('  #%-6d %-58s %s', p.id, p.address.to_s.truncate(56), p.district.presence || '—')
    end
    puts '  (кандидатов нет)' if result.candidates.empty?
  end
end
