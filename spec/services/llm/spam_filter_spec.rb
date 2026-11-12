# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::SpamFilter do
  let(:visitor) { 'visitor-token-1' }

  describe '.classify' do
    context 'IP-репутация' do
      it 'IP из ipsum-списка → тихий дроп до проверки ссылок' do
        SpamBlockedEntry.create!(entry_type: :ip, value: '203.0.113.66', status: :blocked, source: 'ipsum_l3')

        result = described_class.classify('какая погода?', ip: '203.0.113.66', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_ip)
      end

      it 'обычный IP пропускается' do
        expect(described_class.classify('купить квартиру', ip: '198.51.100.10', visitor_token: visitor)[:action])
          .to eq(:pass)
      end
    end

    context 'доменные списки' do
      it 'ссылка на blocked-домен → дроп' do
        SpamBlockedEntry.create!(entry_type: :domain, value: 'botmasterru.com', status: :blocked, source: 'local')

        result = described_class.classify('продвижение ботов http://www.botmasterru.com/product52284/',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_link)
        expect(result[:matches].map(&:value)).to include('botmasterru.com')
      end

      it 'легитимная ссылка на наш домен не режется' do
        result = described_class.classify('смотрите https://victory62.org/properties — интересно?',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:pass)
      end

      it 'белый домен из известных (t.me) без эвристик не режется' do
        result = described_class.classify('наш канал t.me/victory62 — подписывайтесь',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:pass)
      end

      it 'IDN-омограф ловится: запись в punycode матчит кириллический URL' do
        normalized = Llm::SpamUrls.normalize('http://sberbаnk.ru/x') # «а» кириллическая
        SpamBlockedEntry.create!(entry_type: :domain, value: normalized[:host], status: :blocked, source: 'phishing_domains')

        result = described_class.classify('войдите http://sberbаnk.ru/x для оплаты',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
      end
    end

    context 'карантин suspect' do
      it 'suspect-ссылка: сообщение проходит, hit записывается' do
        entry = SpamBlockedEntry.create!(entry_type: :domain, value: 'fishy.example',
                                         status: :suspect, source: 'local')

        result = described_class.classify('что скажете про fishy.example ?',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:pass)
        expect(entry.reload.hits).to eq(1)
      end

      it 'эвристики (стоп-слова) кладут новый домен в suspect' do
        result = described_class.classify(
          'купить подписчиков и продвижение ботов на spam-service-now.example — дёшево',
          ip: '198.51.100.10', visitor_token: visitor
        )

        expect(result[:action]).to eq(:pass)
        entry = SpamBlockedEntry.find_by(value: 'spam-service-now.example')
        expect(entry).to be_present
        expect(entry).to be_status_suspect
        expect(entry.source).to eq('local')
      end

      it 'allowlist-домен с плохим путём: карантин на уровне URL, не домена' do
        SpamAllowlistEntry.create!(domain: 't.me')

        described_class.classify('продвижение ботов t.me/spam_channel недорого',
                                 ip: '198.51.100.10', visitor_token: visitor)

        expect(SpamBlockedEntry.find_by(entry_type: :domain, value: 't.me')).to be_nil
        entry = SpamBlockedEntry.find_by(entry_type: :url, value: 't.me/spam_channel')
        expect(entry).to be_present
        expect(entry).to be_status_suspect
      end

      it 'URL-shortener из hagezi-фида сам по себе эвристика: неизвестный путь → suspect' do
        # шортенеры синкаются как suspect (блок всех bit.ly — самострел)
        SpamBlockedEntry.create!(entry_type: :domain, value: 'bit.ly', status: :suspect, source: 'hagezi_shorteners')

        described_class.classify('смотри bit.ly/xyz123 интересное',
                                 ip: '198.51.100.10', visitor_token: visitor)

        expect(SpamBlockedEntry.find_by(entry_type: :url, value: 'bit.ly/xyz123')).to be_present
      end

      it 'кворум: один домен от 3 разных сессий → автоблок' do
        described_class.classify('продвижение ботов на spam-quorum.example',
                                 ip: '198.51.100.10', visitor_token: 'v-a')
        described_class.classify('продвижение ботов на spam-quorum.example',
                                 ip: '198.51.100.11', visitor_token: 'v-b')

        entry = SpamBlockedEntry.find_by(value: 'spam-quorum.example')
        expect(entry).to be_status_suspect

        described_class.classify('продвижение ботов на spam-quorum.example',
                                 ip: '198.51.100.12', visitor_token: 'v-c')

        expect(entry.reload).to be_status_blocked
      end
    end

    context 'безопасность от самострела' do
      it 'allowlisted-домен с эвристиками, но БЕЗ пути в тексте — не карантинируется' do
        SpamAllowlistEntry.create!(domain: 'youtube.com')

        described_class.classify('смотрите продвижение ботов на youtube.com бесплатно',
                                 ip: '198.51.100.10', visitor_token: visitor)

        expect(SpamBlockedEntry.find_by(value: 'youtube.com')).to be_nil
        expect(SpamBlockedEntry.find_by(entry_type: :url, value: 'youtube.com')).to be_nil
      end
    end
  end
end
