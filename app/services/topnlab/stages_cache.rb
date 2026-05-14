# frozen_string_literal: true

require 'yaml'

module Topnlab
  # Кэш Topnlab stage_id'ов для воронки покупателей (scope_id = -1).
  #
  # Источник правды — `config/topnlab_stages.yml`:
  #   - `discovered`  — сырой массив { id, name, ... } из API (обновляется через refresh!)
  #   - `map`         — ручной маппинг наших stage_key ('first_contact', 'show', ...)
  #                     к integer stage_id из Topnlab. Заполняется руководителем АН ОДИН РАЗ.
  #
  # API:
  #   StagesCache.for_buyers          # → { 'first_contact' => 1234, 'show' => 1235, ... }
  #   StagesCache.id_for('show')      # → 1235  (или nil если map не заполнен)
  #   StagesCache.discovered          # → [ { 'id' => 1234, 'name' => 'Контакт-Центр' }, ... ]
  #   StagesCache.refresh!            # дёргает get_stages(-1) и переписывает YAML
  #
  # Поведение когда map ещё не заполнен: `id_for` возвращает nil. Caller (`transfer_client`)
  # принимает stage_id опциональным — поведение Phase 2 сохраняется (CRM stage не меняется).
  class StagesCache
    CONFIG_PATH = Rails.root.join('config/topnlab_stages.yml').freeze
    BUYER_SCOPE = -1

    class << self
      # @return [Hash{String => Integer}] mapping stage_key → topnlab stage_id
      def for_buyers
        load_config.fetch('map', {}).compact
      end

      # @return [Integer, nil]
      def id_for(stage_key)
        for_buyers[stage_key.to_s]
      end

      # @return [Array<Hash>] список { 'id' => Int, 'name' => String, ... }
      def discovered
        load_config.fetch('discovered', [])
      end

      # Дёргает Topnlab API, нормализует ответ и переписывает YAML (`discovered:`).
      # Сохраняет существующий `map:` нетронутым — это ручная конфигурация.
      # @return [Integer] количество обнаруженных стадий
      def refresh!(client: Client.new)
        raw = client.get_stages(BUYER_SCOPE)
        stages = normalize(raw)

        config = load_config
        config['discovered'] = stages
        write_config(config)
        Rails.logger.info("[Topnlab::StagesCache] refreshed: #{stages.size} stages")
        stages.size
      end

      # Сброс in-memory кэша (для тестов после редактирования YAML).
      def reload!
        @config = nil
      end

      private

      def load_config
        @config ||= YAML.safe_load_file(CONFIG_PATH, permitted_classes: [Symbol], aliases: true) || {}
      rescue Errno::ENOENT
        @config = { 'discovered' => [], 'map' => {} }
      end

      def write_config(config)
        File.write(CONFIG_PATH, config.to_yaml)
        @config = config
      end

      # Topnlab возвращает либо Array<Hash>, либо Hash{id_string => Hash} (по аналогии с
      # get_users). Нормализуем в Array<Hash{ 'id' => Int, 'name' => String, ... }>.
      def normalize(raw)
        items =
          case raw
          when Array then raw
          when Hash  then (raw['data'].is_a?(Array) ? raw['data'] : raw.values)
          else []
          end

        items.filter_map do |item|
          next unless item.is_a?(Hash) && item['id']

          {
            'id' => item['id'].to_i,
            'name' => item['name'].to_s,
            'description' => item['description'].to_s
          }
        end
      end
    end
  end
end
