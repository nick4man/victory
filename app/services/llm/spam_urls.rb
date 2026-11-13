# frozen_string_literal: true

module Llm
  # Извлечение и нормализация URL из текста чат-сообщения (issue #219).
  #
  # Нормализация едина для записи и для проверки — без неё блок-лист
  # расходится с входом: IDN-омографы (sberbаnk.ru с русской «а»), www-,
  # query/utm-метки и якоря давали бы разные ключи одного ресурса.
  module SpamUrls
    # tab/LF/CR WHATWG вырезает из URL до разбора — в любом месте, включая
    # схему и разделитель после неё (ht\ttps://…, https:\t//… = https://…,
    # обходы blocked-домена — ревью Kimi, раунды 11–13); разделитель у
    # специальных схем — любое число / и \ (ноль/один/два, https:/host и
    # https:\host — тот же host), поэтому префикс допускает их между любыми
    # своими символами; в остальной части токена разделителем остаётся
    # только пробел
    SCHEME_PREFIX = 'h(?:(?:[\t\n\r]?t){2}|x[\t\n\r]?x)[\t\n\r]?p[\t\n\r]?s?[\t\n\r]?:(?:[\t\n\r]?[/\\\\])*'
    SCHEME_URL_RE = %r{#{SCHEME_PREFIX}[^ <>"']+}i
    SCHEME_PREFIX_RE = %r{\A#{SCHEME_PREFIX}}i
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
      raw.map { |r| strip_trailing_punct(r) }.reject(&:empty?).uniq
    end

    # Концевая пунктуация: схема-URL не срезаем ничего, кроме кавычек обвязки
    # предложения — .!,;:() валидны в пути WHATWG, и фид сохраняет их в ключе:
    # срезка разводила ключ записи фида и ключ проверки сообщения (ревью Kimi,
    # раунды 11–12). «Голые» хоста идут через полный TRAILING_PUNCT со сверкой
    # парности: (t.me/x) → t.me/x, а t.me/x(1) сохраняется.
    def strip_trailing_punct(token)
      return token.sub(/["']+\z/, '') if token.match?(SCHEME_PREFIX_RE)

      t = token
      loop do
        if t.match?(/[.,!?;:]\z/)
          t = t[0..-2]
        elsif (m = t.match(/([)\]}>"'])\z/))
          pairs = { ')' => '(', ']' => '[', '}' => '{', '>' => '<', "'" => "'", '"' => '"' }
          balanced = t.count(pairs[m[1]]) >= t.count(m[1])
          break if balanced

          t = t[0..-2]
        else
          break
        end
      end
      t
    end

    # @param raw [String]
    # @return [Hash, nil] { host:, path: } — host в punycode-lowercase,
    #   path без query/якоря, nil если вход не похож на URL
    def normalize(raw)
      s = raw.to_s.strip
      return nil if s.empty?

      # WHATWG вырезает ASCII tab/LF/CR из URL до разбора: ht\ttps://…,
      # botmaster\tru.com — это валидные ссылки (ревью Kimi, раунд 11)
      s = s.gsub(/[\t\n\r]/, '')

      # WHATWG URL для специальных схем (http/https, в т.ч. defang-hxxp):
      # бэкслеш — разделитель пути, повторные слэши после схемы схлопываются.
      # Браузер из `https:\@evil/x` и `https:///evil/x` получает хост evil, а
      # старая нормализация отбрасывала такой вход и пропускала ссылку мимо
      # blocked-домена: обходы подтверждены WHATWG-разбором в Node.
      if s.match?(%r{\A(?:https?|hxxps?):}i)
        s = s.tr('\\', '/')
        # специальная схема: любое число / и \ после двоеточия схлопывается
        # (https:host, https:/host, https:\\host — один host)
        s = s.sub(%r{\A(?:https?|hxxps?):/*}i, '')
      else
        s = s.sub(%r{\A//}, '')
      end
      s = s.split(/[?#]/).first.to_s
      s = s.gsub(/\s+/, '')
      s = s.sub(%r{/+\z}, '')

      authority, path = s.split('/', 2)
      authority = authority.to_s
      # userinfo не должна менять ключ: https://user@botmasterru.com/x
      # обходил blocked-домен, превращаясь в «user@botmasterru.com». Отделяем
      # по ПОСЛЕДНЕМУ '@' — user@foo@host иначе давал «foo@host». Первый проход
      # — по сырому authority, ДО percent-decoding: %2F/%5C валидны именно в
      # userinfo (WHATWG-URL: new URL('https://%75ser%2Fx@botmasterru.com/x')
      # даёт host == botmasterru.com), а декод всего authority превращал их
      # в слэш и отбрасывал весь вход мимо blocked-домена.
      authority = authority.rpartition('@').last if authority.include?('@')
      # percent-encoding в хосте декодируем до всех проверок: браузер
      # разрешает %62otmasterru.com и botmasterru%2ecom именно в
      # botmasterru.com, а без декода оба обходили blocked-запись. Декодируем
      # раньше порта — иначе %3A (%:8080) разошёлся бы с проверкой ниже.
      # %2F в хосте — мусор, не URL: после декода это слэш, и такой вход
      # отбрасываем, а не гадаем. Байты декодируем единым UTF-8-потоком:
      # побайтовый chr давал бинарную строку, и %D0%B1otmasterru.com
      # (кириллическая «б» — IDN-омограф) отбрасывался вместо punycode,
      # обходя IDN-запись блок-листа.
      authority = decode_percent_utf8(authority)
      return nil if authority.nil?

      return nil if authority.match?(%r{[/\\\s]})
      # второй проход на случай %40 в «хосте» (evil%40botmasterru.com): браузер
      # такой хост не принимает, а нам безопаснее сматчить хост и дропнуть
      authority = authority.rpartition('@').last if authority.include?('@')
      # порт менял ключ: example.com:443 ≠ example.com; пустой порт
      # (example.com:) WHATWG молча отрезает — иначе запись не находилась
      # digest-поиском и пустой порт обходил blocked-домен
      authority = authority.sub(/:\d*\z/, '')
      authority = authority.downcase
      # IDN-разделители (· U+3002, ． U+FF0E, ｡ U+FF61) — точки ДО IDNA:
      # иначе «botmasterru。com» уходил в punycode-лейбл и проверку на '.'
      # проходил мимо, не сматчив blocked-домен
      authority = authority.tr('。．｡', '...')
      # www снимаем после userinfo: https://user@www.evil/x иначе оставлял
      # 'www.evil' и обходил blocked-домен 'evil'
      authority = authority.sub(%r{\Awww\.}i, '')
      authority = authority.sub(/\.\z/, '')   # финальная точка FQDN-стиля
      return nil unless authority.include?('.')

      host = Addressable::IDNA.to_ascii(authority)
      return nil if host.empty? || host.length > 253
      host = host.delete_suffix('.')

      { host: host, path: normalize_path(path) }
    rescue StandardError
      # мусорный вход не должен ронять фильтр — это просто не URL
      nil
    end

    # @param path [String, nil] путь без query/якоря
    # @return [String, nil] путь с убранными dot-сегментами (RFC 3986 §5.2.4)
    #   или nil для корня. Запись и проверка обязаны сводить `/clean/../x`
    #   и `/x` к одному ключу: у URL-only фидов (phishing_links) доменной
    #   записи нет, и несвённый dot-сегмент — полный обход блока пути.
    #   Percent-escape'и над unreserved-символами (`%70` = `p`) декодируем
    #   до свёртки: иначе `/%70hish` обходил blocked `/phish`.
    def normalize_path(path)
      return nil if path.blank?

      p = decode_unreserved("/#{path}")
      # non-ASCII байты пути — в единую каноническую форму: Unicode-URL
      # /фишинг и его percent-encoded эквивалент иначе получали разные ключи,
      # и для URL-only фидов (доменной записи нет) blocked-путь обходился
      # другой написанием (и наоборот). WHATWG сериализует путь percent-encoded
      # с uppercase hex — обе формы сходятся к ней.
      p = decode_multibyte_escapes(p)
      p = remove_dot_segments(p)
      p = p.sub(%r{/*$}, '')
      p = percent_encode_non_ascii(p)
      p.presence
    end

    # Percent-escape'и хоста — единым потоком байт: склеиваем подряд идущие
    # %XX и декодируем как UTF-8. Невалидная последовательность (обрезанная
    # кодовая точка и т.п.) — мусор: WHATWG такой хост не принимает, и вход
    # отбрасываем целиком, а не угадываем.
    def decode_percent_utf8(str)
      str.gsub(/(?:%[0-9a-f]{2})+/i) do |seq|
        decoded = percent_bytes_to_utf8(seq)
        return nil if decoded.nil?

        decoded
      end
    end

    # Байты одной non-ASCII run пути раскодируем в символы: зарезервированные
    # однобайтовые escape'и (%2F и т.п.) не трогаем — '/' из них сломал бы
    # структуру пути. Невалидный UTF-8 и смешанные run с разделителями
    # оставляем как есть (после lowercasing hex — см. decode_unreserved).
    def decode_multibyte_escapes(str)
      str.gsub(/(?:%[0-9a-f]{2})+/i) do |seq|
        bytes = seq.scan(/%([0-9a-f]{2})/i).flatten.map(&:hex)
        next seq.downcase if bytes.all? { |b| b < 0x80 }

        decoded = percent_bytes_to_utf8(seq)
        next seq.downcase if decoded.nil? || decoded.match?(%r{[/\\?#]})

        decoded
      end
    end

    # Каноническая форма non-ASCII в пути — uppercase percent-encoded UTF-8,
    # как сериализует WHATWG: литеральные Unicode-символы и раскодированные
    # escape'и получают один ключ.
    def percent_encode_non_ascii(str)
      str.gsub(/[^\x00-\x7F]/) { |ch| ch.bytes.map { |b| format('%%%02X', b) }.join }
    end

    def percent_bytes_to_utf8(seq)
      bytes = seq.scan(/%([0-9a-f]{2})/i).flatten.map(&:hex)
      decoded = bytes.pack('C*').force_encoding(Encoding::UTF_8)
      decoded.valid_encoding? ? decoded : nil
    end

    # RFC 3986 unreserved — A-Z / a-z / 0-9 / -._~: escape над ними это то
    # же значение, декодируем в символ. Прочие escape'и сохраняем как есть,
    # но hex приводим к нижнему регистру: `%2F` и `%2f` в сыром виде
    # разводили бы разные ключи одного ресурса.
    def decode_unreserved(str)
      str.gsub(/%([0-9a-f]{2})/i) do
        ch = Regexp.last_match(1).hex.chr
        ch.match?(/[a-z0-9.\-_~]/i) ? ch : Regexp.last_match(0).downcase
      end
    end

    # RFC 3986 §5.2.4 remove_dot_segments — побеговая реализация по строке.
    def remove_dot_segments(input)
      output = +''
      until input.empty?
        if input.start_with?('../') || input.start_with?('./')
          input = input[2..]
        elsif input.start_with?('/./') || input == '/.'
          input = input.sub(%r{\A/\./}, '/')
          input = '/' if input == '/.'
        elsif input.start_with?('/../') || input == '/..'
          input = input.sub(%r{\A/\.\./}, '/')
          input = '/' if input == '/..'
          output = output.sub(%r{/[^/]*\z}, '')
        elsif input == '.' || input == '..'
          input = ''
        else
          seg = input[%r{\A/?[^/]*}]
          output << seg
          input = input[seg.length..]
        end
      end
      output
    end
  end
end
