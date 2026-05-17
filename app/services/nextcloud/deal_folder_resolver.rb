# frozen_string_literal: true

module Nextcloud
  # Phase 7.8a — резолвер NC-пути deal folder из Property + Inquiry по naming
  # convention из cheatsheet:
  #
  #   <TopnlabID> <ДЕЙСТВИЕ> <descriptor> <ClientFirstName>
  #
  # @example
  #   r = Nextcloud::DealFolderResolver.for(property: prop, inquiry: inq)
  #   r.path        # => "Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/128248561 ПРОДАЖА 2-ка Сенная Анна"
  #   r.folder_name # => "128248561 ПРОДАЖА 2-ка Сенная Анна"
  #   r.parent_dir  # => "Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ"
  #
  # Pure function — НЕ ходит в NC (только конструирует path). Существование
  # folder проверяется отдельно через Nextcloud::Client#exists?.
  #
  # === Components
  #
  # | Part | Source | Fallback |
  # |---|---|---|
  # | TopnlabID | `Property.external_id` (alias crm_id) | nil → 'NO-ID' (предупреждение в logs) |
  # | ДЕЙСТВИЕ | `Property.deal_type` mapped (sale→ПРОДАЖА, rent→АРЕНДА, daily→АРЕНДА) | — |
  # | descriptor | natural-language (см. #descriptor_for) | бессмысленный fallback по property_type |
  # | ClientFirstName | `Inquiry.name.split.first` | nil → '' (skip) |
  #
  # === Top folder + geo-split
  #
  # | property_type slug | top folder | geo-split | source |
  # |---|---|---|---|
  # | flat | КВАРТИРЫ | yes (РЯЗАНЬ/МОСКВА/...) | Property.address |
  # | room | КОМНАТЫ | no | — |
  # | house | ДОМА | no | — |
  # | land | ЗЕМЛЯ | yes | — |
  # | commerce | НЕЖИЛЫЕ ЗДАНИЯ- ПОМЕЩЕНИЯ | no | — |
  # | garage | ГАРАЖИ | no | — |
  class DealFolderResolver
    NC_ROOT = 'Офис/НЕДВИЖИМОСТЬ'

    DEAL_TYPE_MAP = {
      'sale' => 'ПРОДАЖА',
      'rent' => 'АРЕНДА',
      'daily' => 'АРЕНДА' # посуточная — тот же top-level действия что и долгосрочная
    }.freeze

    TOP_FOLDER = {
      'flat' => 'КВАРТИРЫ',
      'room' => 'КОМНАТЫ',
      'house' => 'ДОМА',
      'land' => 'ЗЕМЛЯ',
      'commerce' => 'НЕЖИЛЫЕ ЗДАНИЯ- ПОМЕЩЕНИЯ',
      'garage' => 'ГАРАЖИ'
    }.freeze

    GEO_SPLIT_TYPES = ['flat', 'land'].freeze

    GEO_PATTERNS = [
      [/\bРяза/i,          'РЯЗАНЬ'],
      [/\bМоскв/i,         'МОСКВА'],
      [/Санкт.Петер|СПб/i, 'САНКТ-ПЕТЕРБУРГ']
    ].freeze

    Result = Struct.new(:path, :parent_dir, :folder_name, :exists, keyword_init: true) do
      def to_s = path
    end

    def self.for(property:, inquiry: nil)
      new(property: property, inquiry: inquiry).call
    end

    def initialize(property:, inquiry: nil)
      @property = property
      @inquiry  = inquiry
    end

    def call
      parent = parent_dir_for(@property)
      name   = folder_name_for(@property, @inquiry)
      Result.new(path: "#{parent}/#{name}", parent_dir: parent, folder_name: name)
    end

    private

    def parent_dir_for(property)
      type_slug = property.property_type&.slug.to_s
      top = TOP_FOLDER[type_slug] || 'НЕИЗВЕСТНЫЙ ТИП'

      base = "#{NC_ROOT}/#{top}"
      return base unless GEO_SPLIT_TYPES.include?(type_slug)

      geo = geo_split_for(property.address)
      geo.present? ? "#{base}/#{geo}" : base
    end

    def geo_split_for(address)
      return nil if address.blank?

      match = GEO_PATTERNS.find { |re, _| address.match?(re) }
      match&.last
    end

    def folder_name_for(property, inquiry)
      [topnlab_id(property),
       action_for(property),
       descriptor_for(property),
       client_first_name(inquiry)].compact_blank.join(' ')
    end

    def topnlab_id(property)
      id = begin
        property.external_id.presence || property.crm_id
      rescue StandardError
        property.external_id.presence
      end
      id.presence || 'NO-ID'
    end

    def action_for(property)
      DEAL_TYPE_MAP[property.deal_type.to_s] || property.deal_type.to_s.upcase.presence || 'СДЕЛКА'
    end

    # Краткое описание для имени папки. Не пытается быть полным address — это
    # «человеческое» имя в которое user может добавить улицу/кв. № при ручном
    # ensure_folder!. Что мы строим автоматически — минимум, понятный для агента.
    def descriptor_for(property)
      case property.property_type&.slug
      when 'flat'  then flat_descriptor(property)
      when 'house' then 'Дом'
      when 'room'  then 'Комната'
      when 'land'  then 'Участок'
      when 'commerce' then 'Коммерция'
      when 'garage' then 'Гараж'
      else property.property_type&.name.to_s.presence || 'объект'
      end
    end

    def flat_descriptor(property)
      rooms = property.try(:rooms_count) || property.try(:rooms)
      return "#{rooms}-ка" if rooms.to_i.between?(1, 5)

      'Квартира'
    end

    def client_first_name(inquiry)
      return nil if inquiry.nil?

      raw = inquiry.respond_to?(:client_name) ? inquiry.client_name : inquiry.name
      raw.to_s.strip.split(/\s+/).first
    end
  end
end
