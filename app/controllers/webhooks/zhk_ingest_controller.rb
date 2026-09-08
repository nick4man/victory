# frozen_string_literal: true

module Webhooks
  # Приём батча наблюдений от services/zhk-registry (питоновский сборщик
  # открытых источников о новостройках Рязани). Аутентификация bearer-
  # токеном: пустой ENV['ZHK_INGEST_TOKEN'] отказывает всем запросам, а не
  # пропускает их — молчаливое «проверка отключена» на пустом секрете при
  # неверном деплое было бы дырой.
  #
  # Пустой секрет отвечает 503, а не 403 (как у NewsIngestController) —
  # расхождение с соседом здесь НАМЕРЕННОЕ, а не недосмотр. Пустой ENV —
  # ошибка конфигурации СЕРВЕРА (забыли положить секрет при деплое), а не
  # вина клиента: 403 говорит сборщику «не пущу никогда, брось повторять»,
  # хотя настоящий смысл обратный — «сейчас чиним, попробуй ещё раз».
  # `TopnlabController` в этой же кодовой базе уже отвечает 503 на пустой
  # секрет, и здесь тот же случай. Унификацию news_ingest/topnlab на 5xx
  # эта задача не делает — записано долгом отдельно. Неверный (но
  # непустой) токен — по-прежнему 401: это действительно вина клиента.
  #
  # Решение о том, что применить к карточке ЖК, принимает исключительно
  # `Zhk::Ingest.call` — этот контроллер не содержит доменной логики,
  # только приём, авторизацию и раскладку батча на поэлементные ответы.
  #
  # Каждое наблюдение применяется НЕЗАВИСИМО от соседей: `Zhk::Ingest.call`
  # транзакционен на уровне одного наблюдения, а не батча целиком, поэтому
  # оборачивать здесь весь массив в одну транзакцию нельзя — иначе одно
  # битое наблюдение откатило бы уже применённые соседние. Один плохой
  # элемент из пятидесяти — обычный, ожидаемый исход, а не авария: ответ
  # всегда 200 с поэлементным отчётом, где у каждого наблюдения свой
  # `status`. Пятисотка здесь означала бы «повтори весь батч», а сборщик
  # ретраил бы уже применённые (`:created`/`:updated`) наблюдения заново —
  # `Zhk::Ingest` идемпотентен, так что повтор не испортит данные, но
  # обманул бы сборщика лишней работой и скрыл настоящую причину отказа
  # части батча за общей пятисоткой. `:invalid` для конкретного элемента —
  # это «не примем никогда, не ретрай», и сборщик должен узнать об этом из
  # тела ответа, а не из кода статуса.
  #
  # 422 без обработки — только два случая, оба на уровне батча целиком, а
  # не отдельного наблюдения: тело не по контракту (не объект, нет
  # `observations`, `observations` не массив) и батч длиннее `MAX_BATCH`.
  # В обоих случаях в базу не пишется вообще ничего — обрабатывать нечего.
  class ZhkIngestController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false
    before_action :authenticate_bearer!

    MAX_BATCH = 50

    def create
      observations = params[:observations]
      unless observations.is_a?(Array)
        return render json: { error: 'invalid_payload', detail: 'observations must be an array' },
                      status: :unprocessable_entity
      end

      if observations.size > MAX_BATCH
        return render json: { error: 'batch_too_large', max: MAX_BATCH }, status: :unprocessable_entity
      end

      # `observations: []` — законный, а не мусорный вход: сборщику
      # нечего слать в этот цикл обхода (например, все источники уже
      # проверены и ничего не изменилось). Это не отличается от «часть
      # батча невалидна» по духу правила «отдаём 422 только когда
      # обрабатывать нечего вообще» — обрабатывать здесь как раз ЕСТЬ
      # что: пустой список, для которого пустой отчёт — корректный ответ,
      # а не 422.
      render json: { results: observations.map { |raw| apply(raw) } }
    end

    # Сводка одного прогона `run.py` — присылается ПОСЛЕ всех батчей
    # `create`, когда обход всех источников (успешных и упавших) уже
    # закончен. `Zhk::RunSummary.call` сам решает, молчал ли какой-то
    # источник против своей обычной нормы — контроллер здесь не содержит
    # доменной логики, только приём и доставку в TG, как и `create` не
    # содержит логики применения наблюдения.
    #
    # `counts` — не `params.require(:counts).to_unsafe_h` напрямую: у
    # скалярного `counts` (например `{"counts": 5}`) нет `to_unsafe_h`, и
    # это был бы необработанный `NoMethodError` → 500 вместо законного
    # 422 (круг правок 1, симметрично проверке `observations.is_a?(Array)`
    # в `create` выше).
    #
    # ЗНАЧЕНИЯ проверяются там же и по той же причине: форма контейнера
    # без формы содержимого закрывает половину дыры. `Zhk::RunSummary`
    # везде зовёт `count.to_i`, а у вложенного объекта или массива
    # (`{"counts": {"erz": {"a": 1}}}`) метода `to_i` нет вовсе — снова
    # `NoMethodError` → 500 на входе, который контроллер обязан отвергать
    # сам. Проверка нарочно ЛОЯЛЬНАЯ (число или строка, читаемая как
    # число): сборщик шлёт JSON-целые, но 422 здесь стоит не разобранной
    # сводки, а сводка — единственный носитель тревоги о молчащем
    # источнике; сужать её приём строже необходимого дороже, чем принять
    # "7".
    #
    # `delivered` в ответе — не декоративное поле: `run.py` обязан узнать,
    # дошла ли сводка ДО сотрудников, а не только принял ли её сервер.
    # Без этого поля молчаливый отказ Telegram (не настроен
    # `TELEGRAM_STAFF_CHAT_ID`, TG недоступен) выглядел бы для сборщика
    # как полный успех — а тревога о молчащем источнике как раз и была бы
    # тем сообщением, которое не дошло.
    def summary
      raw_counts = params[:counts]
      unless raw_counts.is_a?(ActionController::Parameters)
        return render json: { error: 'invalid_payload', detail: 'counts must be an object' },
                      status: :unprocessable_entity
      end

      counts = raw_counts.to_unsafe_h
      bad_key = counts.keys.find { |key| !countable?(counts[key]) }
      if bad_key
        return render json: { error: 'invalid_payload',
                              detail: "counts[#{bad_key}] must be a number" },
                      status: :unprocessable_entity
      end

      text = Zhk::RunSummary.call(counts)
      delivered = notify_staff(text)
      render json: { status: 'ok', delivered: delivered }
    end

    private

    # Значение `counts`, которое `Zhk::RunSummary` сможет и привести к
    # числу через `to_i`, и записать в `ZhkIngestRun`. Два разных условия,
    # и оба обязаны проверяться ЗДЕСЬ:
    #
    #   * `to_i` — у хеша, массива, `nil` и булева его нет вовсе:
    #     необработанный `NoMethodError` → 500;
    #   * неотрицательность — `ZhkIngestRun` валидирует
    #     `numericality: { greater_than_or_equal_to: 0 }`, и `-1` дожил бы
    #     до `create!` в `record_run`, где `RecordInvalid` вышел бы наружу
    #     HTML-страницей исключения. Формально это тоже 422, но НЕ тот
    #     JSON-контракт (`{error: 'invalid_payload', …}`), который
    #     контроллер обещает во всех остальных случаях, — потребитель
    #     разбирает тело, а не только код статуса.
    #
    # Отрицательное число наблюдений не имеет смысла ни в одном источнике
    # (`run.py` считает через `len()`/`sum()`), поэтому отвергаем его на
    # входе, а не на записи: у входной проверки есть контракт ответа, у
    # `create!` — нет. Проверка неотрицательности стоит и на числовой
    # ветке, а не только в регэкспе строки: JSON-целое `-1` приходит
    # `Integer`, регэкспа не касается вовсе, и одна лишь строгость
    # `\A\d+\z` дыру бы не закрыла.
    #
    # В остальном проверка нарочно лояльная: строка, читаемая как целое
    # («7»), принимается — у произвольной строки `to_i` тоже есть, но
    # отдаёт молчаливый 0, а молчаливый ноль в счётчике источника это
    # ложная тревога о молчании (или, хуже, скрытая настоящая).
    def countable?(value)
      case value
      when Integer, Float then value >= 0
      when String then value.strip.match?(/\A\d+\z/)
      else false
      end
    end

    # Уведомление — best-effort в смысле «не рушит HTTP-ответ», но НЕ
    # best-effort в смысле «неважно, дошло ли»: возвращает `true`/`false`,
    # и `summary` обязан прокинуть это наружу (см. комментарий выше про
    # `delivered`). К моменту вызова `summary` все наблюдения этого
    # прогона уже применены предыдущими вызовами `create` — сама сводка
    # ничего не пишет в справочник, поэтому сбой её ДОСТАВКИ не должен
    # превращать уже успешно обработанный прогон в 500 для сборщика.
    #
    # `rescue StandardError`, а не узкий `Telegram::Client::Error`
    # (круг правок 1): `Telegram::Client#api_call` ходит через
    # `Net::HTTP.start` напрямую и оборачивает в `Telegram::Client::Error`
    # только ответ API вида `{"ok": false}` — таймаут (`Net::OpenTimeout`,
    # `Net::ReadTimeout`), сбой DNS (`SocketError`) или обрыв соединения
    # долетели бы отсюда НЕ обёрнутыми. Перечислять эти классы поимённо
    # означало бы гарантированно забыть один (ещё `OpenSSL::SSL::SSLError`,
    # `Errno::ECONNRESET`, `EOFError`...) — здесь риск пропустить класс
    # исключения дороже риска поймать что-то лишнее: назначение метода
    # ровно в том, чтобы сбой ДОСТАВКИ сводки никогда не долетал до
    # клиента как 500.
    def notify_staff(text)
      chat_id = ENV['TELEGRAM_STAFF_CHAT_ID'].presence
      unless chat_id
        Rails.logger.warn('[ZhkIngest#summary] TELEGRAM_STAFF_CHAT_ID не задан — сводка не отправлена')
        return false
      end

      Telegram::Client.new.send_message(text, chat_id: chat_id)
      true
    rescue StandardError => e
      Rails.logger.warn("[ZhkIngest#summary] не удалось отправить сводку в Telegram: #{e.class} #{e.message}")
      false
    end

    # Один элемент батча. Форма `raw` заранее не гарантирована — служба
    # сбора могла прислать не-объект внутри массива (`["мусор"]`); в этом
    # случае `to_unsafe_h` недоступен, и в `Zhk::Ingest.call` уезжает то,
    # что есть — сам сервис отличает не-хеш от валидного наблюдения и
    # отвечает `:invalid`, а не бросает исключение наружу.
    def apply(raw)
      payload = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      result = Zhk::Ingest.call(payload)

      {
        external_id: payload.is_a?(Hash) ? payload['external_id'] : nil,
        status: result.status,
        complex_id: result.complex_id,
        discrepancies: result.discrepancies,
        reasons: result.reasons
      }
    end

    def authenticate_bearer!
      configured = ENV['ZHK_INGEST_TOKEN'].to_s
      if configured.empty?
        Rails.logger.warn('[ZhkIngest] ZHK_INGEST_TOKEN не задан — отклоняем всё (503, это наша поломка)')
        head :service_unavailable and return
      end

      # Схема обязательна явно: значение без префикса `Bearer `, даже
      # побайтово совпадающее с секретом, не аутентифицирует.
      # NewsIngestController в этой же кодовой базе принимает и голое
      # значение (наследие, которое мы туда не тащим) — здесь сборщик
      # наш собственный, и слабина, которую нечем оправдать, не нужна.
      header = request.headers['Authorization'].to_s
      unless header.start_with?('Bearer ')
        head :unauthorized
        return
      end

      provided = header.split(' ', 2).last.to_s
      head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, configured)
    end
  end
end
