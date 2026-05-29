import { test, expect } from '@playwright/test';

test.describe('Express valuation — /valuations', () => {
  test('form initial state (empty)', async ({ page }) => {
    await page.goto('/valuations');
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveScreenshot('valuation-empty.png', {
      fullPage: true,
    });
  });

  test('form with sample inputs filled', async ({ page }) => {
    await page.goto('/valuations');

    // Fill a representative sample so the post-submit view (if any
    // inline calculator) gets exercised. Adjust selectors to match the
    // actual form field names — placeholders below are guesses based
    // on Property's columns.
    const addr = page.locator('input[name*="address"]').first();
    if (await addr.count()) await addr.fill('Рязань, Канищево, ул. Тестовая, 1');

    const area = page.locator('input[name*="area"]').first();
    if (await area.count()) await area.fill('54');

    const rooms = page.locator('select[name*="rooms"], input[name*="rooms"]').first();
    if (await rooms.count()) await rooms.fill('2');

    await page.waitForLoadState('networkidle');

    await expect(page).toHaveScreenshot('valuation-filled.png', {
      fullPage: true,
      mask: [page.locator('[data-no-snapshot]')],
    });
  });
});
