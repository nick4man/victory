# frozen_string_literal: true

module Zhk
  # Готовность карточки ЖК к публикации. Один источник правды для админки
  # и для `rake zhk:coverage` — иначе экран и консоль разъедутся в оценке.
  module Coverage
    PHOTO_DIR  = 'images/zhk'
    PHOTO_GLOB = '*.{jpg,jpeg,webp}'

    module_function

    # @return [Array<String>] пустой массив = карточка готова
    def marks_for(complex, listings_count:, photos_count:)
      marks = []
      marks << 'нет текста'      if complex.body_html.blank?
      marks << 'нет фото'        if photos_count.to_i.zero?
      marks << 'нет объектов'    if listings_count.to_i.zero?
      marks << 'не опубликован'  unless complex.published?
      marks
    end

    # Один glob на всю страницу вместо Dir.glob на каждую строку.
    # @return [Hash{String=>Integer}] slug => сколько фото
    def photo_counts_by_slug
      root = Rails.public_path.join(PHOTO_DIR)
      return {} unless root.directory?

      root.children.select(&:directory?).to_h do |dir|
        [dir.basename.to_s, dir.glob(PHOTO_GLOB).size]
      end
    end

    # Риск 4 плана: шаблонная проза по ЖК одного застройщика — классическая
    # смерть программного SEO. Ловим совпадение первого абзаца.
    # @return [Hash{String=>Array<String>}] первый абзац => имена ЖК
    def duplicate_first_paragraphs
      ResidentialComplex.unscoped.not_deleted
                        .where.not(body_plain: [nil, ''])
                        .pluck(:name, :body_plain)
                        .group_by { |(_name, plain)| plain.to_s.lines.first.to_s.strip }
                        .select { |lead, rows| lead.present? && rows.size > 1 }
                        .transform_values { |rows| rows.map(&:first) }
    end
  end
end
