# frozen_string_literal: true

require 'rails_helper'

# Регресс на хардненинг get-ids (prod-инцидент «каталог → 0»).
# Не-массивный 200 (error-shaped body / null) или 404 должны трактоваться как
# ошибка fetch, а НЕ как легитимно пустая выгрузка — иначе Importer#archive_missing
# обнулит весь каталог. Легитимный [] обязан оставаться валидным без raise.
RSpec.describe Topnlab::Client do
  subject(:client) { described_class.new(api_key: 'test-key', base_url: base_url) }

  let(:base_url)  { 'https://crm.example' }
  let(:get_ids_re) { %r{\Ahttps://crm\.example/get-ids} }

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  describe '#get_ids' do
    it 'возвращает массив ids при 200 + JSON-массиве' do
      stub_request(:get, get_ids_re).to_return(status: 200, body: [1, 2, 3].to_json)

      expect(client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat')).to eq([1, 2, 3])
    end

    it 'возвращает [] при легитимно пустой выгрузке и НЕ бросает' do
      stub_request(:get, get_ids_re).to_return(status: 200, body: [].to_json)

      result = nil
      expect { result = client.get_ids(type: 'realty', action: 'sale', realty_type: 'garage') }
        .not_to raise_error
      expect(result).to eq([]) # один вызов: избегаем 6s SLOW_DELAY-throttle между двумя get_ids
    end

    it 'бросает Error на 200 с error-shaped телом (не-массив)' do
      stub_request(:get, get_ids_re).to_return(status: 200, body: { status: 'error' }.to_json)

      expect { client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat') }
        .to raise_error(Topnlab::Client::Error, /не-массив/)
    end

    it 'бросает Error на 200 с телом null' do
      stub_request(:get, get_ids_re).to_return(status: 200, body: 'null')

      expect { client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat') }
        .to raise_error(Topnlab::Client::Error, /не-массив/)
    end

    it 'бросает Error на 404 (parse → nil → не-массив)' do
      stub_request(:get, get_ids_re).to_return(status: 404, body: '')

      expect { client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat') }
        .to raise_error(Topnlab::Client::Error, /не-массив/)
    end

    it 'не утаскивает api-key в текст исключения (он уходит в error_log и в админку)' do
      stub_request(:get, get_ids_re)
        .to_return(status: 200, body: { status: 'error', request: { key: 'test-key' } }.to_json)

      expect { client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat') }
        .to raise_error(Topnlab::Client::Error) { |e|
          expect(e.message).not_to include('test-key')
          expect(e.message).to include('FILTERED')
        }
    end
  end

  describe '#get_entities' do
    let(:get_entities_re) { %r{\Ahttps://crm\.example/get-entities} }

    it 'мержит чанки при 200 + JSON-объекте' do
      stub_request(:get, get_entities_re)
        .to_return(status: 200, body: { '1' => { 'id' => 1 } }.to_json)

      expect(client.get_entities([1])).to eq('1' => { 'id' => 1 })
    end

    it 'возвращает {} без запроса, если ids пуст' do
      expect(client.get_entities([])).to eq({})
      expect(a_request(:get, get_entities_re)).not_to have_been_made
    end

    # Ключевой регресс: раньше не-Hash молча пропускался (`merge! if is_a?(Hash)`),
    # seen_ids оставался неполным при fetch_errors == 0 → archive снимал живые.
    # `{"status":"error"}` — тоже Hash, поэтому проверки is_a?(Hash) мало:
    # он бы смержился, дал ноль id и разблокировал archive при fetch_errors == 0.
    it 'бросает Error на 200 с error-shaped телом (Hash, но не карта сущностей)' do
      stub_request(:get, get_entities_re)
        .to_return(status: 200, body: { status: 'error' }.to_json)

      expect { client.get_entities([1]) }
        .to raise_error(Topnlab::Client::Error, /не карту сущностей/)
    end

    it 'бросает Error на пустой массив — мы запросили конкретные id' do
      stub_request(:get, get_entities_re).to_return(status: 200, body: [].to_json)

      expect { client.get_entities([1]) }
        .to raise_error(Topnlab::Client::Error, /не карту сущностей/)
    end

    it 'бросает Error на пустой Hash — запрошенные id обязаны вернуться' do
      stub_request(:get, get_entities_re).to_return(status: 200, body: {}.to_json)

      expect { client.get_entities([1]) }
        .to raise_error(Topnlab::Client::Error, /не карту сущностей/)
    end
  end

  # importClient не идемпотентен: повторная отправка после сетевого сбоя заводит
  # вторую заявку. ReadTimeout/ECONNRESET/EPIPE могут случиться уже ПОСЛЕ того,
  # как Topnlab принял запрос — поэтому на них ни одного повтора. OpenTimeout —
  # соединение не установилось, запрос точно не ушёл — единственное исключение,
  # которое ретраится (тот же backoff, что и у остальных вызовов клиента).
  describe '#import_client' do
    let(:import_re) { %r{\Ahttps://crm\.example/call/main/importClient/} }

    it 'ReadTimeout после отправки — НЕ повторяет запрос, сразу бросает Error' do
      stub_request(:post, import_re)
        .to_raise(Net::ReadTimeout).then
        .to_return(status: 200, body: { status: 'ok', insertedId: 4455 }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error, /сетевой сбой после отправки, повтор не выполнялся/)

      expect(a_request(:post, import_re)).to have_been_made.once
    end

    it 'EOFError посреди обмена — без повтора, ошибка клиента вместо сырого исключения' do
      stub_request(:post, import_re)
        .to_raise(EOFError).then
        .to_return(status: 200, body: { status: 'ok', insertedId: 4455 }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error, /повтор не выполнялся/)

      expect(a_request(:post, import_re)).to have_been_made.once
    end

    it 'ECONNRESET после отправки — тоже без повтора и с неоднозначным исходом' do
      stub_request(:post, import_re)
        .to_raise(Errno::ECONNRESET).then
        .to_return(status: 200, body: { status: 'ok', insertedId: 4455 }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::AmbiguousError, /сетевой сбой после отправки/)

      expect(a_request(:post, import_re)).to have_been_made.once
    end

    it 'ReadTimeout после отправки — неоднозначный исход (AmbiguousError)' do
      stub_request(:post, import_re).to_raise(Net::ReadTimeout)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::AmbiguousError, /проверь CRM перед повторной выгрузкой/)
    end

    # Регресс ревью PR #210 (round 7): ответ, пришедший ПОСЛЕ возможной
    # обработки запроса (5xx, битое/неожиданное тело 200), не доказывает,
    # что заявка не создана — неоднозначный исход, не явный отказ CRM.
    it 'HTTP 502 — AmbiguousError, а не явный отказ' do
      stub_request(:post, import_re).to_return(status: 502, body: 'Bad Gateway')

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::AmbiguousError, /HTTP 502/)
    end

    it 'malformed JSON в ответе 200 — AmbiguousError' do
      stub_request(:post, import_re).to_return(status: 200, body: '<html>cut off')

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::AmbiguousError, /invalid JSON/)
    end

    it '200 с телом без поля status — AmbiguousError' do
      stub_request(:post, import_re).to_return(status: 200, body: ['unexpected', 'shape'].to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::AmbiguousError, /телом без status/)
    end

    # Регресс ревью PR #210: отражённый в теле ответа appkey попадал в текст
    # ошибки → в export_error, журнал переходов и Telegram-модераторов.
    # Round 8: в сообщение идёт только allowlist безопасных полей
    # (status/message/error), отражение ключа внутри message вычищает
    # value-scrub.
    it 'ошибочный ответ, отражающий ключ в message, — appkey вычищен из текста ошибки' do
      stub_request(:post, import_re)
        .to_return(status: 200, body: { status: 'error', message: 'duplicate key=test-key' }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('FILTERED')
        expect(e.message).not_to include('test-key')
      }
    end

    it 'HTTP-ошибка с телом, отражающим ключ, — тоже вычищена (путь через parse)' do
      stub_request(:post, import_re)
        .to_return(status: 500, body: { error: 'boom', appkey: 'test-key' }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('FILTERED')
        expect(e.message).not_to include('test-key')
      }
    end

    # Регресс ревью PR #210 (round 5): сериализованный JSON внутри строки
    # ломает regex scrub'а (экранированные кавычки) — значение ключа
    # вычищается напрямую, независимо от формы вложенности.
    it 'appkey внутри сериализованного JSON в строке — вычищен из текста ошибки' do
      stub_request(:post, import_re)
        .to_return(status: 200, body: { status: 'error', message: { appkey: 'test-key' }.to_json }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('FILTERED')
        expect(e.message).not_to include('test-key')
      }
    end

    it 'сырое тело HTTP-ошибки с экранированным JSON — ключ тоже вычищен' do
      stub_request(:post, import_re)
        .to_return(status: 500, body: '{"status":"error","message":"{\\"appkey\\":\\"test-key\\"}"}')

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('FILTERED')
        expect(e.message).not_to include('test-key')
      }
    end

    # Регресс ревью PR #210 (round 8, блокер 2): полное тело ответа
    # отражает запрос — телефон, имя, комментарий, email агента. Ошибка
    # формируется из allowlist безопасных полей, PII в неё не попадает.
    it 'отражённые в теле ответа phone/fullname/comment/user_mail — не попадают в ошибку' do
      stub_request(:post, import_re)
        .to_return(status: 200, body: {
                     status: 'error',
                     request: {
                       phone: '79001234567', fullname: 'Иван Петров',
                       comment: 'звонить после 18', user_mail: 'agent@example.com'
                     },
                     message: 'duplicate'
                   }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('duplicate')
        expect(e.message).not_to include('79001234567', 'Иван Петров', 'звонить после 18', 'agent@example.com')
      }
    end

    it 'PII в теле HTTP-ошибки — тоже не попадает в ошибку (путь через parse)' do
      stub_request(:post, import_re)
        .to_return(status: 500, body: {
                     error: 'boom',
                     request: { phone: '79001234567', user_mail: 'agent@example.com' }
                   }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).not_to include('79001234567', 'agent@example.com')
      }
    end

    # Регресс ревью PR #210 (round 9, блокер 1): filter_pii удалял только
    # PII-КЛЮЧИ структуры, а сериализованный JSON внутри строкового message
    # проходил целиком — телефон и ФИО уезжали в export_error и Telegram.
    it 'PII внутри сериализованного JSON в message — не попадает в ошибку' do
      stub_request(:post, import_re)
        .to_return(status: 200, body: {
                     status: 'error',
                     message: { phone: '79001234567', fullname: 'Иван Петров', code: 409 }.to_json
                   }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('409')
        expect(e.message).not_to include('79001234567', 'Иван Петров')
      }
    end

    # Регресс round 9 (блокер 1): не-JSON тело HTTP-ошибки содержит PII
    # запроса — safe_body_excerpt вычищает значения тела запроса, а не только
    # appkey.
    it 'PII в не-JSON теле HTTP-ошибки — не попадает в ошибку' do
      stub_request(:post, import_re)
        .to_return(status: 400, body: 'rejected: phone=79001234567 fullname=Иван Петров key=test-key')

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('FILTERED')
        expect(e.message).not_to include('79001234567', 'Иван Петров', 'test-key')
      }
    end

    # Регресс round 9 (блокер, parse): текст JSON::ParserError содержит
    # фрагмент сырого тела ответа — битый JSON, отразивший ключ/PII запроса,
    # увёз бы секрет в сообщение исключения мимо scrub тела.
    it 'битый JSON 200, отразивший ключ и PII, — секрет не попадает в ошибку' do
      stub_request(:post, import_re)
        .to_return(status: 200, body: '{"x":test-key "phone":"79001234567"}')

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')
      end.to raise_error(Topnlab::Client::AmbiguousError) { |e|
        expect(e.message).to include('invalid JSON')
        expect(e.message).not_to include('test-key', '79001234567')
      }
    end

    # Регресс round 9 (пропуск PII): короткие значения запроса (имя «Аня»)
    # раньше не вычищались из-за порога ≥ 4 — теперь идут по границам слова.
    it 'короткое имя (3 символа) в ошибке — вычищено из текста' do
      stub_request(:post, import_re)
        .to_return(status: 200, body: { status: 'error', message: 'duplicate Аня' }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Аня', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('[FILTERED]')
        expect(e.message).not_to include('Аня')
      }
    end

    # Регресс round 9++ (блокер): CRM отражает запрос в JSON-escaped виде —
    # перевод строки в комментарии уходит по проводу как \n, и точная
    # подстрока с реальным переводом строки в отражении не совпадает.
    it 'комментарий с переводом строки в JSON-escaped отражении — вычищен из текста' do
      comment = "звонить после 18\nДоп. телефон: +79005553535"
      stub_request(:post, import_re)
        .to_return(status: 200, body: { status: 'error', message: "duplicate: #{comment.to_json[1..-2]}" }.to_json)

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form', comment: comment)
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('duplicate', '[FILTERED]')
        expect(e.message).not_to include('Доп. телефон', '79005553535', 'звонить после 18')
      }
    end

    # Регресс round 9 (пропуск PII): сырое тело ответа может содержать имя
    # в \\uXXXX-форме — экранирование в фрагменте ошибки не декодируется,
    # прямой gsub литерала её не ловит.
    it 'имя в \\uXXXX-форме в не-JSON теле ошибки — вычищено из текста' do
      stub_request(:post, import_re)
        .to_return(status: 400, body: 'rejected \u0410\u043D\u044F key=test-key')

      expect do
        client.import_client(phone: '+7 900 123-45-67', name: 'Аня', source: 'site_form')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('[FILTERED]')
        expect(e.message).not_to include('\u0410', 'Аня', 'test-key')
      }
    end

    it 'OpenTimeout (соединение не установилось) — повторяет как обычно и успевает' do
      stub_request(:post, import_re)
        .to_raise(Net::OpenTimeout).then
        .to_return(status: 200, body: { status: 'ok', insertedId: 4455 }.to_json)
      # Отдельный (не subject) инстанс: стабим sleep, чтобы не ждать реальный
      # backoff, а RSpec/SubjectStub запрещает стабить методы объекта под тестом.
      retrying_client = described_class.new(api_key: 'test-key', base_url: base_url)
      allow(retrying_client).to receive(:sleep)

      result = retrying_client.import_client(phone: '+7 900 123-45-67', name: 'Иван Петров', source: 'site_form')

      expect(result).to eq('status' => 'ok', 'insertedId' => 4455)
      expect(a_request(:post, import_re)).to have_been_made.twice
    end
  end

  describe '#transfer_client' do
    let(:transfer_re) { %r{/call/main/transferClient/} }

    # Тот же регресс, что и для import_client: тело ответа отражает запрос
    # (appkey), без scrub ключ уехал бы в error_log и Telegram.
    it 'ошибочный ответ, отражающий ключ в message, — appkey вычищен из текста ошибки' do
      stub_request(:post, transfer_re)
        .to_return(status: 200, body: { status: 'error', message: 'no agent key=test-key' }.to_json)

      expect do
        client.transfer_client(order_id: 4455, email: 'agent@victory62.org')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('FILTERED')
        expect(e.message).not_to include('test-key')
      }
    end

    # Тот же регресс round 5: сериализованный JSON внутри строки.
    it 'appkey внутри сериализованного JSON в строке — вычищен из текста ошибки' do
      stub_request(:post, transfer_re)
        .to_return(status: 200, body: { status: 'error', message: { appkey: 'test-key' }.to_json }.to_json)

      expect do
        client.transfer_client(order_id: 4455, email: 'agent@victory62.org')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('FILTERED')
        expect(e.message).not_to include('test-key')
      }
    end

    # Регресс round 9 (блокер 2): 200 с телом null/массив/скаляр — раньше
    # filter_pii(res).slice(...) на таких значениях бросал NoMethodError/
    # ArgumentError мимо контракта Topnlab::Client::Error, а потребители
    # (LeadStageTransition) ловят только Error.
    it 'ответ 200 null — Topnlab::Client::Error, а не NoMethodError' do
      stub_request(:post, transfer_re).to_return(status: 200, body: 'null')

      expect do
        client.transfer_client(order_id: 4455, email: 'agent@victory62.org')
      end.to raise_error(Topnlab::Client::Error, /не JSON-объект/)
    end

    it 'ответ 200 массивом — Topnlab::Client::Error, а не ArgumentError' do
      stub_request(:post, transfer_re).to_return(status: 200, body: [].to_json)

      expect do
        client.transfer_client(order_id: 4455, email: 'agent@victory62.org')
      end.to raise_error(Topnlab::Client::Error, /не JSON-объект/)
    end

    it 'ответ 200 JSON-скаляром — Topnlab::Client::Error' do
      stub_request(:post, transfer_re).to_return(status: 200, body: '"ok"')

      expect do
        client.transfer_client(order_id: 4455, email: 'agent@victory62.org')
      end.to raise_error(Topnlab::Client::Error, /не JSON-объект/)
    end

    # Регресс round 9 (блокер 1): email агента из тела запроса, отражённый
    # в message, не должен доехать до текста ошибки → Outcome#warning.
    it 'email агента, отражённый в message, — вычищен из текста ошибки' do
      stub_request(:post, transfer_re)
        .to_return(status: 200, body: { status: 'error', message: 'no such agent agent@victory62.org' }.to_json)

      expect do
        client.transfer_client(order_id: 4455, email: 'agent@victory62.org')
      end.to raise_error(Topnlab::Client::Error) { |e|
        expect(e.message).to include('no such agent', '[FILTERED]')
        expect(e.message).not_to include('agent@victory62.org')
      }
    end
  end
end
