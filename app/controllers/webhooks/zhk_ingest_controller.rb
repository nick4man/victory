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
    def summary
      counts = params.require(:counts).to_unsafe_h
      text = Zhk::RunSummary.call(counts)
      notify_staff(text)
      render json: { status: 'ok' }
    end

    private

    # Уведомление — best-effort. К моменту вызова `summary` все наблюдения
    # этого прогона уже применены предыдущими вызовами `create`: сводка
    # только информирует сотрудников, сама по себе она ничего не пишет в
    # справочник. Поэтому сбой Telegram (токен/чат не настроены, TG
    # недоступен) не должен превращать уже успешно обработанный прогон в
    # 500 для сборщика — тому нечего было бы чинить в ответ на такой сбой,
    # а важные данные он уже доставил раньше.
    def notify_staff(text)
      chat_id = ENV['TELEGRAM_STAFF_CHAT_ID'].presence
      unless chat_id
        Rails.logger.warn('[ZhkIngest#summary] TELEGRAM_STAFF_CHAT_ID не задан — сводка не отправлена')
        return
      end

      Telegram::Client.new.send_message(text, chat_id: chat_id)
    rescue Telegram::Client::Error => e
      Rails.logger.warn("[ZhkIngest#summary] не удалось отправить сводку в Telegram: #{e.message}")
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
