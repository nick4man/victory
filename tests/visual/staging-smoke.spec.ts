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
  for (const [path, text] of PAGES) {
    test(`${path} отвечает и рендерится`, async ({ page }) => {
      const response = await page.goto(path);
      expect(response?.status(), `${path}: HTTP status`).toBe(200);
      // Страница ошибки Rails — это тоже 200 с «что-то пошло не так» в некоторых
      // конфигурациях; проверяем осмысленный контент, а не только код.
      await expect(page.locator('h1').first()).toBeVisible();
      await expect(page.getByText(text).first()).toBeVisible();
    });
  }
});
