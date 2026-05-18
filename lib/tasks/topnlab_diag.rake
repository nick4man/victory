# frozen_string_literal: true

# Diagnostic helpers для Topnlab integration — печатают raw payload
# нужные поля (`rooms`, `realty_type`, `area_room`, etc.) для ручной
# верификации mapping'а после изменений в PropertyMapper.
#
# Использование:
#   bin/rake 'topnlab:dump_rooms[100760595,69728824,98795669]'
#
# Печатает per-external_id одну строку JSON со значимыми полями. Не
# логировать в общий лог — payload может содержать данные клиента.
namespace :topnlab do
  desc 'Dump room-related fields of given Topnlab external IDs'
  task :dump_rooms, [:ids] => :environment do |_t, args|
    raw = args[:ids] || ENV.fetch('IDS', '')
    ids = raw.to_s.split(/[,\s]+/).map(&:strip).reject(&:blank?).map(&:to_i)
    if ids.empty?
      warn 'Usage: bin/rake "topnlab:dump_rooms[id1,id2,...]"'
      exit 1
    end

    payloads = Topnlab::Client.new.get_entities(ids)
    fields = %w[id realty_type rooms room_type rooms_deal area area_room area_kitchen title]

    ids.each do |id|
      data = payloads[id.to_s] || payloads[id]
      if data.blank?
        puts({ id: id, found: false }.to_json)
        next
      end
      summary = fields.each_with_object({}) { |k, h| h[k] = data[k] if data.key?(k) }
      puts(summary.to_json)
    end
  end
end
