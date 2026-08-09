# frozen_string_literal: true

# A2 — справочник ЖК (08.08.26).
namespace :zhk do
  desc 'Засеять стартовый справочник ЖК (идемпотентно)'
  task seed: :environment do
    load Rails.root.join('db/seeds/residential_complexes.rb')
  end

  desc 'Показать покрытие справочника: контент / фото / объекты'
  task coverage: :environment do
    ResidentialComplex.unscoped.not_deleted.order(:name).each do |c|
      photos = Rails.public_path.join("images/zhk/#{c.slug}").glob('*.jpg').size
      marks  = []
      marks << 'нет текста' if c.body_html.blank?
      marks << 'нет фото'   if photos.zero?
      marks << 'нет объектов' if c.on_site_listings_count.zero?
      marks << 'не опубликован' unless c.published?

      status = marks.empty? ? 'готов' : marks.join(', ')
      puts format('%-34s %-22s %s', c.name, c.district_slug.to_s, status)
    end
  end
end
