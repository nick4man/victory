// Навигационный smoke против staging — БЕЗ скриншотов.
//
// Визуальные снапшоты против staging бессмысленны: базовые PNG сняты с
// dev-данными, а на staging — копия прода, попиксельно они разойдутся всегда.
// Этот спек проверяет другое: ключевые страницы отвечают 200 и рендерят
// осмысленный контент (не страницу ошибки). Запускается только в CI после
// staging-выкатки (build.yml, джоба playwright-staging):
//   npx playwright test staging-smoke

import { test, expect } from '@playwright/test';

const PAGES: Array<[string, string | RegExp]> = [
  ['/', 'Виктори'],
  ['/properties', /квартир|объект|недвижим/i],
  ['/news', /новост/i],
  ['/zhk', /новострой|жил.*комплекс|ЖК/i],
  ['/contacts', /контакт/i],
];

test.describe('Staging smoke — публичные страницы', () => {
  // Спек живёт в общем testDir и попадает в локальный `npm run vr:test`.
  // Без staging-URL (и basic-auth) он бессмысленен — пропускаем, а не падаем.
  test.skip(!process.env.PLAYWRIGHT_BASE_URL, 'staging-only: нужен PLAYWRIGHT_BASE_URL');

  for (const [path, text] of PAGES) {
    test(`${path} отвечает и рендерится`, async ({ page }) => {
      // domcontentloaded, а не load: /contacts тянет карту (сторонний
      // iframe), и на слабом стенде событие load уходит за 30 с — мобильный
      // тест таймаутился ещё до ассертов (11.10.26).
      const response = await page.goto(path, { waitUntil: 'domcontentloaded' });
      expect(response?.status(), `${path}: HTTP status`).toBe(200);
      // Страница ошибки Rails — это тоже 200 с «что-то пошло не так» в некоторых
      // конфигурациях; проверяем осмысленный контент, а не только код.
      await expect(page.locator('h1').first()).toBeVisible();
      // toContainText по body, а не видимость первого совпадения: getByText
      // находил скрытый дубль ссылки из мобильного меню («Контакты») и падал
      // с "hidden" (5 из 10 тестов, первый CI-прогон 11.10.26).
      await expect(page.locator('body')).toContainText(text);
    });
  }
});
