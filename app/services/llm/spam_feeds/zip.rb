# frozen_string_literal: true

module Llm
  module SpamFeeds
    # Минимальный распаковщик первого файла zip-архива. Tranco отдаёт
    # список только как top-1m.csv.zip, а rubyzip тянуть в проект ради
    # одной ежесуточной выгрузки не хочется. Достаточно stored/deflate
    # методов и local file header — ровно то, что пишет `zip`/Tranco.
    module Zip
      LOCAL_HEADER_SIG = "PK\u0003\u0004".b

      module_function

      # @return [String, nil] распакованное содержимое первого файла
      def first_file(data)
        blob = data.to_s.b
        idx = blob.index(LOCAL_HEADER_SIG)
        return nil unless idx

        # local file header: sig(4) ver(2) flags(2) method(2) time(2) date(2)
        #                    crc(4) csize(4) usize(4) nlen(2) elen(2)
        fields = blob[idx + 4, 26].unpack('vvvvvVVVvv')
        method = fields[2]
        compressed_size = fields[6]
        name_len = fields[8]
        extra_len = fields[9]
        return nil if compressed_size.zero? # data descriptor — размер в central directory

        payload = blob[idx + 30 + name_len + extra_len, compressed_size]
        case method
        when 0 then payload
        when 8 then Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(payload)
        end
      rescue StandardError
        nil # битый архив — синк отработает в 0, allowlist останется прежним
      end
    end
  end
end
