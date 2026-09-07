# frozen_string_literal: true

# Заглушки внешних сервисов для всего сьюта.
#
# До 08.08.26 в rails_helper стоял `WebMock.allow_net_connect!`, и тесты ходили
# в реальный интернет. Последствия были не косметические: прогон отправлял
# ~51 настоящее сообщение через боевого staff-бота (@anvictorybot) и дёргал
# Nominatim, а Property-спеки падали с OpenSSL::SSL::SSLError, когда внешний
# сервис был недоступен.
#
# Теперь сеть закрыта (`disable_net_connect!`), а типовые исходящие вызовы
# отвечают здесь канонными заглушками. Спек, которому нужен другой ответ,
# объявляет свой `stub_request` — он объявлен позже и потому побеждает.

RSpec.configure do |config|
  config.before do
    # ── Telegram Bot API ──────────────────────────────────────────────────
    # Ловим любой метод у любого токена: в спеках встречаются sendMessage,
    # editMessageText, sendPhoto, answerCallbackQuery. Ответ — минимальный
    # валидный Message, которого хватает всем вызывающим.
    stub_request(:any, %r{\Ahttps://api\.telegram\.org/bot[^/]+/\w+})
      .to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: {
          ok: true,
          result: {
            message_id: 1,
            date: 0,
            chat: { id: -1_003_779_115_845, type: 'supergroup' },
            text: 'stubbed'
          }
        }.to_json
      )

    # ── Nominatim (geocoder) ──────────────────────────────────────────────
    # Дублирует Geocoder lookup: :test ниже — страховка на случай прямого
    # HTTP в обход гема.
    stub_request(:get, %r{\Ahttps://nominatim\.openstreetmap\.org/})
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: '[]')
  end
end

# Geocoder: :test-lookup вместо HTTP. Дефолтный stub возвращает Рязань —
# спеки, которым нужны конкретные координаты, добавляют свой
# `Geocoder::Lookup::Test.add_stub`.
if defined?(Geocoder)
  Geocoder.configure(lookup: :test, ip_lookup: :test)

  Geocoder::Lookup::Test.set_default_stub(
    [
      {
        'coordinates' => [54.6269, 39.6916],
        'address' => 'Рязань, Рязанская область, Россия',
        'state' => 'Рязанская область',
        'country' => 'Россия',
        'country_code' => 'RU'
      }
    ]
  )
end
