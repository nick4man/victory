# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::SpamUrls do
  describe '.extract' do
    it 'достаёт обычные http/https-ссылки' do
      expect(described_class.extract('смотри http://www.botmasterru.com/product52284/ тут'))
        .to contain_exactly('http://www.botmasterru.com/product52284/')
    end

    it 'достаёт обфускацию hxxp' do
      expect(described_class.extract('hxxps://evil.example/x'))
        .to contain_exactly('hxxps://evil.example/x')
    end

    it 'достаёт «голый» домен без схемы' do
      expect(described_class.extract('заходи botmasterru.com срочно'))
        .to contain_exactly('botmasterru.com')
    end

    it 'достаёт разделённый пробелами домен' do
      expect(described_class.extract('промо botmasterru .com дёшево'))
        .to include('botmasterru.com')
    end

    it 'не цепляет обычный текст и пунктуацию' do
      expect(described_class.extract('купить квартиру, 2 комн. м. Московская, 54 м.кв. — срочно!'))
        .to eq([])
    end
  end

  describe '.normalize' do
    it 'lowercase, без www, без query и якоря' do
      expect(described_class.normalize('HTTP://WWW.Example.COM/path/?utm_source=x#frag'))
        .to eq(host: 'example.com', path: '/path')
    end

    it 'hxxp-обфускация приводится к http-виду' do
      expect(described_class.normalize('hxxp://www.Evil.EXAMPLE/a'))
        .to eq(host: 'evil.example', path: '/a')
    end

    it 'IDN-омограф с русской «а» уходит в punycode' do
      normalized = described_class.normalize('http://sberbаnk.ru/login') # «а» кириллическая

      expect(normalized[:host]).to start_with('xn--')
      # латинский вариант того же домена — другая запись: без единой
      # нормализации омограф обошёл бы блок-лист другим написанием
      expect(described_class.normalize('http://sberbank.ru/login')[:host]).to eq('sberbank.ru')
      expect(normalized[:host]).not_to eq('sberbank.ru')
    end

    it 'кириллический домен нормализуется в punycode' do
      expect(described_class.normalize('https://мос.рф/дом')[:host]).to start_with('xn--')
    end

    it 'голый домен без пути' do
      expect(described_class.normalize('botmasterru.com')).to eq(host: 'botmasterru.com', path: nil)
    end

    it 'корневой путь "/" → path nil' do
      expect(described_class.normalize('https://example.com/')).to eq(host: 'example.com', path: nil)
    end

    it 'порт и финальная точка не меняют ключ: обходы нормализации' do
      expect(described_class.normalize('https://example.com:443/path')).to eq(host: 'example.com', path: '/path')
      expect(described_class.normalize('https://example.com./path')).to eq(host: 'example.com', path: '/path')
      expect(described_class.normalize('https://example.com:8080')).to eq(host: 'example.com', path: nil)
    end

    it 'userinfo не меняет ключ: https://user@example.com/x — тот же хост' do
      expect(described_class.normalize('https://user@example.com/x')).to eq(host: 'example.com', path: '/x')
      expect(described_class.normalize('http://me:pass@botmasterru.com/y'))
        .to eq(host: 'botmasterru.com', path: '/y')
    end

    it 'www после userinfo снимается: user@www.evil — тот же хост, что evil' do
      expect(described_class.normalize('https://user@www.botmasterru.com/x'))
        .to eq(host: 'botmasterru.com', path: '/x')
    end

    it 'IDN-разделители (· U+3002, ． U+FF0E, ｡ U+FF61) — это точки' do
      %w[。 ． ｡].each do |sep|
        expect(described_class.normalize("https://botmasterru#{sep}com/x"))
          .to eq(host: 'botmasterru.com', path: '/x'), "разделитель #{sep.inspect}"
      end
      # IDN-домен с IDN-разделителем всё равно уходит в punycode
      expect(described_class.normalize('https://сбербанк。ру/x')[:host]).to start_with('xn--')
    end

    it 'percent-encoded хост декодируется: %62otmasterru.com = botmasterru.com' do
      expect(described_class.normalize('https://%62otmasterru.com/x'))
        .to eq(host: 'botmasterru.com', path: '/x')
    end

    it 'точка через %2e проходит проверку домена: botmasterru%2ecom = botmasterru.com' do
      expect(described_class.normalize('https://botmasterru%2ecom/x'))
        .to eq(host: 'botmasterru.com', path: '/x')
    end

    it 'percent-encoded userinfo и порт не меняют ключ' do
      expect(described_class.normalize('https://%75ser%40botmasterru.com:443/x'))
        .to eq(host: 'botmasterru.com', path: '/x')
    end

    it 'слэш через %2F в хосте — мусор, не URL' do
      expect(described_class.normalize('https://botmasterru.com%2Fevil/x')).to be_nil
    end

    it 'dot-сегменты сводятся: /clean/../phish/login = /phish/login' do
      expect(described_class.normalize('https://shared-host.example/clean/../phish/login'))
        .to eq(host: 'shared-host.example', path: '/phish/login')
    end

    it 'dot-сегменты через percent-encoded точки: /clean/%2e%2e/phish = /phish' do
      expect(described_class.normalize('https://shared-host.example/clean/%2E%2e/phish'))
        .to eq(host: 'shared-host.example', path: '/phish')
    end

    it 'одиночный /./ не меняет путь; /phish/.. → корень' do
      expect(described_class.normalize('https://example.com/a/./b'))
        .to eq(host: 'example.com', path: '/a/b')
      expect(described_class.normalize('https://example.com/phish/..'))
        .to eq(host: 'example.com', path: nil)
    end

    it 'выход за корень не портит ключ: /../x = /x' do
      expect(described_class.normalize('https://example.com/../x'))
        .to eq(host: 'example.com', path: '/x')
    end

    it 'unreserved-символы в пути декодируются из %XX: %70 = p, ключ тот же' do
      expect(described_class.normalize('https://example.com/%70hish/%6cogin'))
        .to eq(host: 'example.com', path: '/phish/login')
    end

    it 'зарезервированные эскейпы пути сохраняются, hex приводится к нижнему регистру' do
      expect(described_class.normalize('https://example.com/a%2Fb'))
        .to eq(host: 'example.com', path: '/a%2fb')
    end

    it 'мусор не падает, возвращает nil' do
      expect(described_class.normalize('not a url')).to be_nil
    end
  end
end
