# frozen_string_literal: true

module Zhk
  # Подбор объектов каталога, которые стоит привязать к ЖК.
  #
  # Порядок критериев продиктован замером данных 09.08.26, а не теорией:
  # `geom` заполнен у 100% Property, а `district` пуст у 12 из 18 объектов
  # на сайте, поэтому радиус первичен, а район — лишь сужение. При этом ни
  # у одного засеянного ЖК координат пока НЕТ, так что стратегия :none —
  # не экзотика, а самый частый сегодня случай. Ради него есть `all`:
  # весь пул непривязанных, единственный работающий способ привязать
  # что-либо, пока редактор не проставил широту/долготу.
  class AttachmentSuggester
    Result = Struct.new(:strategy, :candidates, :notes, :pool_size, keyword_init: true)

    RADIUS_KM  = 0.3
    STRATEGIES = %w[auto radius patterns district all].freeze

    def self.call(complex, strategy: nil, radius_km: nil, query: nil)
      new(complex, strategy: strategy, radius_km: radius_km, query: query).call
    end

    def initialize(complex, strategy: nil, radius_km: nil, query: nil)
      @complex   = complex
      @strategy  = STRATEGIES.include?(strategy.to_s) ? strategy.to_s : 'auto'
      @radius_km = (radius_km.presence || RADIUS_KM).to_f
      @query     = query.presence
    end

    def call
      chosen, scope = resolve
      scope = filter_by_query(scope)

      Result.new(
        strategy:  chosen,
        candidates: scope.order(created_at: :desc),
        notes:     notes_for(chosen),
        pool_size: pool.count
      )
    end

    private

    attr_reader :complex, :query

    # Каскад, а не объединение: union залил бы оператора инвентарём целого
    # района поверх точного попадания по радиусу.
    def resolve
      return ['all', pool] if @strategy == 'all'
      return ['radius', by_radius] if @strategy == 'radius' && coordinates?
      return ['patterns', by_patterns] if @strategy == 'patterns' && patterns?
      return ['district', by_district] if @strategy == 'district' && district_aliases.present?

      if coordinates?            then ['radius', by_radius]
      elsif patterns?            then ['patterns', by_patterns]
      elsif district_aliases.present? then ['district', by_district]
      else ['none', Property.none]
      end
    end

    # Непривязанные активные объекты того же города — общая база всех веток.
    def pool
      Property.on_site.where(residential_complex_id: nil).in_city(complex.city)
    end

    def by_radius
      pool.within_radius(complex.latitude, complex.longitude, @radius_km)
    end

    # ILIKE индекс не использует — на сотне строк каталога это неважно.
    def by_patterns
      patterns = Array(complex.address_patterns).compact_blank
      return Property.none if patterns.empty?

      sql = patterns.each_index.map { |i| "address ILIKE :p#{i}" }.join(' OR ')
      binds = patterns.each_with_index.to_h do |pattern, i|
        # sanitize_sql_like — иначе % и _ в паттерне станут джокерами.
        [:"p#{i}", "%#{Property.sanitize_sql_like(pattern.strip)}%"]
      end

      pool.where(sql, **binds)
    end

    # Только через aliases_for: в колонке district лежит free-text алиас,
    # прямой where(district: slug) не сработает никогда. Для слага вне
    # реестра метод возвращает nil — отсюда .presence, иначе получили бы
    # where(district: nil).
    def by_district
      pool.where(district: district_aliases)
    end

    def district_aliases
      @district_aliases ||= begin
        mod = Cities.districts_module(city_slug)
        Array(mod.respond_to?(:aliases_for) ? mod.aliases_for(complex.district_slug) : nil).presence
      end
    end

    def filter_by_query(scope)
      return scope if query.blank?

      scope.where('address ILIKE :q', q: "%#{Property.sanitize_sql_like(query)}%")
    end

    def coordinates?
      complex.latitude.present? && complex.longitude.present?
    end

    def patterns?
      Array(complex.address_patterns).compact_blank.any?
    end

    def city_slug
      Cities::REGISTRY.find { |_slug, cfg| cfg[:name] == complex.city }&.first || Cities::DEFAULT_SLUG
    end

    # Молчаливый пустой экран — худший исход: оператор не поймёт, чинить
    # ему карточку или в каталоге правда ничего нет.
    def notes_for(chosen)
      notes = []
      notes << 'У ЖК не заданы координаты — поиск по радиусу недоступен. Заполните широту и долготу в карточке.' unless coordinates?
      notes << 'Не заданы адресные паттерны — поиск по адресу недоступен.' unless patterns?
      if district_aliases.blank?
        notes << 'Не задан район — сужение по району недоступно.'
      elsif chosen == 'district'
        notes << 'Район заполнен не у всех объектов каталога: те, у кого он пуст, сюда не попадут. Используйте «все непривязанные».'
      end
      notes << 'Ни одного сигнала для подбора — переключитесь на «все непривязанные».' if chosen == 'none'
      notes
    end
  end
end
