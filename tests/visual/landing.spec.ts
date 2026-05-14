import { test, expect } from '@playwright/test';

test.describe('Landing — /', () => {
  test('hero + featured properties + news carousel — fullpage', async ({ page }) => {
    await page.goto('/');

    // Wait for the hero slider to stop transitioning so the first slide
    // is locked when we screenshot. Cached for 10 min server-side so
    // the same property set is rendered across runs.
    await page.waitForSelector('#hero-slider', { state: 'visible' });
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveScreenshot('landing-fullpage.png', {
      fullPage: true,
      // Hide elements that legitimately change between runs (current time,
      // analytics counters, etc.). Add selectors as the page grows.
      mask: [page.locator('[data-no-snapshot]')],
    });
  });

  test('hero only — viewport', async ({ page }) => {
    await page.goto('/');
    await page.waitForSelector('#hero-slider', { state: 'visible' });
    await expect(page.locator('#hero-slider')).toHaveScreenshot('landing-hero.png');
  });
});
