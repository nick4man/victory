/**
 * Cloudflare Worker: Telegram webhook relay для АН «Виктори».
 *
 * Зачем: прямой TG → victory62.org/webhooks/telegram блокируется
 * (host firewall или upstream provider режут TG IP-диапазоны 91.108.4.0/22
 * и 149.154.160.0/20). Worker принимает webhook на CF Edge (IP-адрес
 * Cloudflare, не в TG-диапазоне) и форвардит на наш Rails. Все запросы
 * от Worker'а — обычные HTTPS, проходят через любой firewall.
 *
 * Архитектура:
 *   TG → CF Worker → Rails (https://victory62.org/webhooks/telegram)
 *
 * Free план CF Workers: 100K req/день, у нас ~1000.
 */

const UPSTREAM_URL = 'https://victory62.org/webhooks/telegram';
// Тестовый бот (песочница карточек CRM): setWebhook на <worker>/test.
const TEST_UPSTREAM_URL = 'https://victory62.org/webhooks/telegram_test';

// Защита от случайных POST'ов кем-то снаружи: TG отправляет
// заголовок X-Telegram-Bot-Api-Secret-Token если в setWebhook
// передан secret_token. Worker сверяет с CF Secret TELEGRAM_WEBHOOK_SECRET
// (устанавливается через `wrangler secret put TELEGRAM_WEBHOOK_SECRET`).
// Если secret не выставлен в CF — проверка пропускается (open mode).

export default {
  async fetch(request, env) {
    // Health-check / browser visit
    if (request.method !== 'POST') {
      return new Response('Telegram webhook relay (Victory). POST only.', {
        status: 200,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' }
      });
    }

    const isTest = new URL(request.url).pathname === '/test';
    const got = request.headers.get('X-Telegram-Bot-Api-Secret-Token');
    if (isTest) {
      // Для тестового бота секрет обязателен: вход новый, open mode не нужен.
      if (!env.TELEGRAM_TEST_WEBHOOK_SECRET || got !== env.TELEGRAM_TEST_WEBHOOK_SECRET) {
        return new Response('forbidden', { status: 403 });
      }
    } else if (env.TELEGRAM_WEBHOOK_SECRET && got !== env.TELEGRAM_WEBHOOK_SECRET) {
      // Опциональная проверка secret token основного бота (если CF secret выставлен)
      return new Response('forbidden', { status: 403 });
    }

    // Forward тело без изменений + forward TG secret-token header,
    // чтобы Rails-side также мог провалидировать (defense-in-depth).
    // ДО фикса 19.05.26 header strip'ался → Rails отбраковывал все
    // webhook'и с 'secret_token mismatch'.
    const body = await request.text();
    const tgSecret = request.headers.get('X-Telegram-Bot-Api-Secret-Token');
    const upstreamHeaders = { 'Content-Type': 'application/json' };
    if (tgSecret) {
      upstreamHeaders['X-Telegram-Bot-Api-Secret-Token'] = tgSecret;
    }

    let upstream;
    try {
      upstream = await fetch(isTest ? TEST_UPSTREAM_URL : UPSTREAM_URL, {
        method: 'POST',
        headers: upstreamHeaders,
        body
      });
    } catch (e) {
      // Сеть упала — возвращаем 502, TG ретраит
      return new Response('upstream_unreachable: ' + e.message, { status: 502 });
    }

    // Telegram не парсит тело ответа, только status. Главное — 2xx.
    // Если Rails вернул 5xx — пробросим (TG ретраит), иначе 200.
    if (upstream.status >= 500) {
      return new Response('upstream_5xx', { status: 502 });
    }
    return new Response('ok', { status: 200 });
  }
};
