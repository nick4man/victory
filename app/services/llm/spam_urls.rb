# frozen_string_literal: true

module Llm
  # Извлечение и нормализация URL из текста чат-сообщения (issue #219).
  #
  # Нормализация едина для записи и для проверки — без неё блок-лист
  # расходится с входом: IDN-омографы (sberbаnk.ru с русской «а»), www-,
  # query/utm-метки и якоря давали бы разные ключи одного ресурса.
  module SpamUrls
    SCHEME_URL_RE = %r{(?:https?|hxxps?)://[^\s<>"']+}i
    # «голый» хост латиницей с необязательным путём. Кириллица в regex
    # намеренно запрещена: иначе «м.кв» в описании квартиры читался бы
    # как домен и улетал в карантин.
    BARE_HOST_RE = %r{\b[a-z0-9](?:[a-z0-9-]{0,61}\.)+[a-z]{2,24}(?:/[^\s<>"']*)?}i
    # разделённые пробелами домены («botmasterru .com») — типовая обфускация.
    # Одна точка тоже матчится (группа в середине — *): иначе «botmasterru .com»
    # не дотянул бы до обязательной «внутренней» точки.
    SPACED_HOST_RE = /\b[a-z0-9][a-z0-9-]{0,61}(?:\s?\.\s?[a-z0-9-]{1,61})*\s?\.\s?[a-z]{2,24}\b/i
    TRAILING_PUNCT = /[.,!?;:)\]}"']+\z/

    module_function

    # @param text [String]
    # @return [Array<String>] сырые найденные URL/хоста (до нормализации)
    # Порядок важен: сначала «цельные» хоста с путём (t.me/spam_channel),
    # потом разделённые пробелами — иначе spaced-regex съедает «t.me» без
    # пути раньше, чем bare-regex доберётся до полного URL.
    def extract(text)
      t = text.to_s
      raw = t.scan(SCHEME_URL_RE)
      rest = t.gsub(SCHEME_URL_RE, ' ')
      raw += rest.scan(BARE_HOST_RE)
      rest = rest.gsub(BARE_HOST_RE, ' ')
      raw += rest.scan(SPACED_HOST_RE).map { |s| s.gsub(/\s+/, '') }
      raw.map { |r| r.sub(TRAILING_PUNCT, '') }.reject(&:empty?).uniq
    end

    # @param raw [String]
    # @return [Hash, nil] { host:, path: } — host в punycode-lowercase,
    #   path без query/якоря, nil если вход не похож на URL
    def normalize(raw)
      s = raw.to_s.strip
      return nil if s.empty?

      s = s.sub(%r{\A(?:https?|hxxps?)://}i, '')
      s = s.sub(%r{\A//}, '')
      s = s.split(/[?#]/).first.to_s
      s = s.gsub(/\s+/, '')
      s = s.sub(%r{\Awww\.}i, '')
      s = s.sub(%r{/+\z}, '')
      return nil unless s.include?('.')

      host, path = s.split('/', 2)
      host = Addressable::IDNA.to_ascii(host.to_s.downcase)
      return nil if host.empty? || host.length > 253

      { host: host, path: path.present? ? "/#{path}" : nil }
    rescue StandardError
      # мусорный вход не должен ронять фильтр — это просто не URL
      nil
    end
  end
end
