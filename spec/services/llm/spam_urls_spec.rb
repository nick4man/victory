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

    it 'мусор не падает, возвращает nil' do
      expect(described_class.normalize('not a url')).to be_nil
    end
  end
end
