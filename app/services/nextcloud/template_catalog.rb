# frozen_string_literal: true

module Nextcloud
  # Phase 7.8a — каталог документ-шаблонов из `ОБРАЗЦЫ ДОКУМЕНТОВ`.
  #
  # Two-tier per cheatsheet:
  #   • PREFER: `Офис/НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ/` (domain, real estate)
  #   • FALLBACK: `Офис/ОБРАЗЦЫ ДОКУМЕНТОВ/` (generic)
  #
  # Read-only — никаких write/move/delete. Используется в `kind=document` tasks
  # (Phase 7.3) и staff chat_tools `nextcloud_list_templates` (Phase 7.5).
  #
  # @example
  #   cat = Nextcloud::TemplateCatalog.new
  #   cat.list                          # => [{name:, type:, size:, modified:}, ...]
  #   cat.find_by_keyword('агентский')  # => {name: 'АГЕНТСКИЙ ДОГОВОР март 2026.docx', ...}
  class TemplateCatalog
    DOMAIN_PATH   = 'Офис/НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ'
    FALLBACK_PATH = 'Офис/ОБРАЗЦЫ ДОКУМЕНТОВ'

    def initialize(client: Nextcloud::Client.new)
      @client = client
    end

    # Все шаблоны (с предпочтением domain-tier; если domain содержит файл —
    # generic-tier не включается чтобы избежать дублей).
    # @return [Array<Hash>] записи WebDAV {name:, type:, size:, modified:}
    def list
      domain = safe_list(DOMAIN_PATH)
      return domain if domain.present?

      safe_list(FALLBACK_PATH)
    end

    def find_by_keyword(keyword)
      key = keyword.to_s.downcase
      return nil if key.blank?

      list.find { |entry| entry[:name].to_s.downcase.include?(key) }
    end

    # Возвращает абсолютный NC path до файла (для последующего create_share).
    # Сначала ищет в domain, потом в fallback.
    def path_for(name)
      [DOMAIN_PATH, FALLBACK_PATH].each do |base|
        entries = safe_list(base)
        hit = entries.find { |e| e[:name] == name }
        return "#{base}/#{name}" if hit
      end
      nil
    end

    private

    def safe_list(path)
      @client.list(path)
    rescue Nextcloud::Client::NotFound, Nextcloud::Client::Forbidden
      []
    rescue Nextcloud::Client::Error => e
      Rails.logger.warn("[Nextcloud::TemplateCatalog] #{path}: #{e.message}")
      []
    end
  end
end
