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

    // Опциональная проверка secret token от Telegram (если CF secret выставлен)
    if (env.TELEGRAM_WEBHOOK_SECRET) {
      const got = request.headers.get('X-Telegram-Bot-Api-Secret-Token');
      if (got !== env.TELEGRAM_WEBHOOK_SECRET) {
        return new Response('forbidden', { status: 403 });
      }
    }

    // Forward тело без изменений
    const body = await request.text();
    let upstream;
    try {
      upstream = await fetch(UPSTREAM_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
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
