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

      it 'связка suspect + IP из ipsum: домен повышается до blocked до тихого дропа' do
        SpamBlockedEntry.create!(entry_type: :ip, value: '203.0.113.66', status: :blocked, source: 'ipsum_l3')
        entry = SpamBlockedEntry.create!(entry_type: :domain, value: 'fishy.example',
                                         status: :suspect, source: 'local')

        result = described_class.classify('продвижение ботов на fishy.example',
                                          ip: '203.0.113.66', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_ip)
        expect(entry.reload).to be_status_blocked
      end

      it 'связка suspect URL + IP из ipsum: URL повышается до blocked' do
        SpamBlockedEntry.create!(entry_type: :ip, value: '203.0.113.66', status: :blocked, source: 'ipsum_l3')
        entry = SpamBlockedEntry.create!(entry_type: :url, value: 't.me/spam_channel',
                                         status: :suspect, source: 'local')

        described_class.classify('заходи t.me/spam_channel', ip: '203.0.113.66', visitor_token: visitor)

        expect(entry.reload).to be_status_blocked
      end

      it 'спам-IP не повышает фидовый suspect: корень шортенера статусом владеет синк' do
        SpamBlockedEntry.create!(entry_type: :ip, value: '203.0.113.66', status: :blocked, source: 'ipsum_l3')
        entry = SpamBlockedEntry.create!(entry_type: :domain, value: 'bit.ly',
                                         status: :suspect, source: 'hagezi_shorteners')

        result = described_class.classify('смотри bit.ly/abc', ip: '203.0.113.66', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(entry.reload).to be_status_suspect
      end

      it 'с обычного IP suspect-домен не повышается без кворума' do
        entry = SpamBlockedEntry.create!(entry_type: :domain, value: 'fishy.example',
                                         status: :suspect, source: 'local')

        described_class.classify('что скажете про fishy.example ?',
                                 ip: '198.51.100.10', visitor_token: visitor)

        expect(entry.reload).to be_status_suspect
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

      it 'userinfo не обходит blocked-домен: https://user@botmasterru.com/x' do
        SpamBlockedEntry.create!(entry_type: :domain, value: 'botmasterru.com', status: :blocked, source: 'local')

        result = described_class.classify('посмотрите https://user@botmasterru.com/x',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_link)
      end

      it 'IDN-разделители не обходят blocked-домен: botmasterru。com / ．com / ｡com' do
        SpamBlockedEntry.create!(entry_type: :domain, value: 'botmasterru.com', status: :blocked, source: 'local')

        %w[。 ． ｡].each do |sep|
          result = described_class.classify("заходите https://botmasterru#{sep}com/x",
                                            ip: '198.51.100.10', visitor_token: visitor)

          expect(result[:action]).to eq(:drop), "разделитель #{sep.inspect} не должен обходить блок"
        end
      end

      it 'percent-encoded userinfo со слэшем не обходит blocked-домен (WHATWG: хост валиден)' do
        SpamBlockedEntry.create!(entry_type: :domain, value: 'botmasterru.com', status: :blocked, source: 'local')

        ['https://%75ser%2Fx@botmasterru.com/x', 'https://%75ser%5Cx@botmasterru.com/x'].each do |spam_url|
          result = described_class.classify("посмотрите #{spam_url}",
                                            ip: '198.51.100.10', visitor_token: visitor)

          expect(result[:action]).to eq(:drop), "#{spam_url} не должен обходить блок"
          expect(result[:reason]).to eq(:spam_link)
        end
      end

      it 'userinfo с www не обходит blocked-домен: https://user@www.botmasterru.com/x' do
        SpamBlockedEntry.create!(entry_type: :domain, value: 'botmasterru.com', status: :blocked, source: 'local')

        result = described_class.classify('посмотрите https://user@www.botmasterru.com/x',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_link)
      end

      it 'percent-encoded хост не обходит blocked-домен: %62otmasterru.com и botmasterru%2ecom' do
        SpamBlockedEntry.create!(entry_type: :domain, value: 'botmasterru.com', status: :blocked, source: 'local')

        ['https://%62otmasterru.com/x', 'https://botmasterru%2ecom/x'].each do |spam_url|
          result = described_class.classify("заходите #{spam_url}",
                                            ip: '198.51.100.10', visitor_token: visitor)

          expect(result[:action]).to eq(:drop), "#{spam_url} не должен обходить блок"
          expect(result[:reason]).to eq(:spam_link)
        end
      end

      it 'dot-сегменты не обходят blocked URL: /clean/../phish/login = /phish/login' do
        # домен белый (allowlist), блок только URL-уровня — как у phishing_links
        SpamAllowlistEntry.create!(domain: 'shared-host.example')
        SpamBlockedEntry.create!(entry_type: :url, value: 'shared-host.example/phish/login',
                                 status: :blocked, source: 'phishing_links')

        result = described_class.classify('войдите https://shared-host.example/clean/../phish/login',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_link)
      end

      it 'dot-сегменты через %2e не обходят blocked URL: /clean/%2e%2e/phish' do
        SpamAllowlistEntry.create!(domain: 'shared-host.example')
        SpamBlockedEntry.create!(entry_type: :url, value: 'shared-host.example/phish',
                                 status: :blocked, source: 'phishing_links')

        result = described_class.classify('войдите https://shared-host.example/clean/%2e%2e/phish',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_link)
      end

      it 'свернутый dot-сегмент не блочит невинный путь: /phish/../clean ≠ /phish' do
        SpamAllowlistEntry.create!(domain: 'shared-host.example')
        SpamBlockedEntry.create!(entry_type: :url, value: 'shared-host.example/phish',
                                 status: :blocked, source: 'phishing_links')

        result = described_class.classify('вот документ https://shared-host.example/phish/../clean',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:pass)
      end

      it 'percent-encoded unreserved в пути не обходит blocked URL: %70hish = phish' do
        SpamAllowlistEntry.create!(domain: 'shared-host.example')
        SpamBlockedEntry.create!(entry_type: :url, value: 'shared-host.example/phish/login',
                                 status: :blocked, source: 'phishing_links')

        result = described_class.classify('войдите https://shared-host.example/%70hish/login',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_link)
      end

      it 'браузерный вариант https:\\@host/x не обходит blocked-домен (WHATWG)' do
        SpamBlockedEntry.create!(entry_type: :domain, value: 'botmasterru.com',
                                 status: :blocked, source: 'hagezi_tif')

        result = described_class.classify('смотри https:\\@botmasterru.com/x',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_link)
      end

      it 'браузерный вариант https:///host/x не обходит blocked-домен (WHATWG)' do
        SpamBlockedEntry.create!(entry_type: :domain, value: 'botmasterru.com',
                                 status: :blocked, source: 'hagezi_tif')

        result = described_class.classify('смотри https:///botmasterru.com/x',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_link)
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

      it 'повторный карантин после soft-delete реанимирует ту же строку, без дублей' do
        described_class.classify('продвижение ботов на revive-quarantine.example — дёшево',
                                 ip: '198.51.100.10', visitor_token: visitor)
        entry = SpamBlockedEntry.find_by!(value: 'revive-quarantine.example')
        entry.update_columns(deleted_at: Time.current)

        described_class.classify('снова продвижение ботов на revive-quarantine.example',
                                 ip: '198.51.100.11', visitor_token: visitor)

        digest = SpamBlockedEntry.digest_for('revive-quarantine.example')
        expect(SpamBlockedEntry.unscoped.where(value_digest: digest).count).to eq(1)
        expect(SpamBlockedEntry.find_by(value: 'revive-quarantine.example').id).to eq(entry.id)
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

      it 'URL-shortener из hagezi-фида сам по себе эвристика: hit считается по домену' do
        # шортенеры синкаются как suspect (блок всех bit.ly — самострел);
        # домен уже на учёте — hits идут на доменную запись, путь не плодим
        entry = SpamBlockedEntry.create!(entry_type: :domain, value: 'bit.ly',
                                         status: :suspect, source: 'hagezi_shorteners')

        described_class.classify('смотри bit.ly/xyz123 интересное',
                                 ip: '198.51.100.10', visitor_token: visitor)

        expect(SpamBlockedEntry.find_by(entry_type: :url, value: 'bit.ly/xyz123')).to be_nil
        expect(entry.reload.hits).to eq(1)
      end

      it 'кворум работает через пути: один домен от 3 разных IP с разными путями → автоблок' do
        # регрессия: hits не должны размываться по отдельным URL-записям
        described_class.classify('продвижение ботов spam-paths.example/a',
                                 ip: '198.51.100.10', visitor_token: 'v-a')
        described_class.classify('продвижение ботов spam-paths.example/b',
                                 ip: '198.51.100.11', visitor_token: 'v-b')
        described_class.classify('продвижение ботов spam-paths.example/c',
                                 ip: '198.51.100.12', visitor_token: 'v-c')

        entry = SpamBlockedEntry.find_by(entry_type: :domain, value: 'spam-paths.example')
        expect(entry).to be_status_blocked
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

      it 'кворум по IP: один IP + три сменных visitor_token НЕ блокирует' do
        # visitor-cookie сбрасывается одним кликом — токен не мера независимости
        %w[v-a v-b v-c].each do |token|
          described_class.classify('продвижение ботов на spam-same-ip.example',
                                   ip: '198.51.100.10', visitor_token: token)
        end

        expect(SpamBlockedEntry.find_by(value: 'spam-same-ip.example')).to be_status_suspect
      end

      it 'кворум по IP не размывается путями: 3 IP с разными путями блокируют домен' do
        described_class.classify('продвижение ботов на spam-paths.example/landing',
                                 ip: '198.51.100.10', visitor_token: 'v-a')
        described_class.classify('продвижение ботов на spam-paths.example/promo',
                                 ip: '198.51.100.11', visitor_token: 'v-b')

        entry = SpamBlockedEntry.find_by(value: 'spam-paths.example')
        expect(entry).to be_status_suspect

        described_class.classify('продвижение ботов на spam-paths.example/sale',
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

      it 'allowlisted-домен со старой domain-записью: путь всё равно уходит в URL-карантин' do
        # регрессия: blocked domain + manual allowlist + эвристика на пути —
        # старая domain-запись не должна гасить path-level защиту ранним return
        SpamBlockedEntry.create!(entry_type: :domain, value: 'popular.example',
                                 status: :blocked, source: 'hagezi_tif')
        SpamAllowlistEntry.create!(domain: 'popular.example')

        described_class.classify('продвижение ботов https://popular.example/phish',
                                 ip: '198.51.100.10', visitor_token: visitor)

        expect(SpamBlockedEntry.find_by(entry_type: :url, value: 'popular.example/phish'))
          .to be_status_suspect
      end

      it 'два «@» в authority не обходят blocked-домен: user@foo@www.botmasterru.com' do
        SpamBlockedEntry.create!(entry_type: :domain, value: 'botmasterru.com',
                                 status: :blocked, source: 'local')

        result = described_class.classify('заходите https://user@foo@www.botmasterru.com/x',
                                          ip: '198.51.100.10', visitor_token: visitor)

        expect(result[:action]).to eq(:drop)
        expect(result[:reason]).to eq(:spam_link)
      end
    end
  end
end
