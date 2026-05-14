import { test, expect } from '@playwright/test';

test.describe('News index — /news', () => {
  test('articles list with carousel + grid', async ({ page }) => {
    await page.goto('/news');
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveScreenshot('articles-index.png', {
      fullPage: true,
      mask: [
        // News carousel auto-rotates — freeze it at slide 0 visually
        // (animation: 'disabled' in config already pauses CSS animations,
        // but the JS-driven swipe may still move).
        page.locator('[data-news-carousel] [data-active-slide]'),
      ],
    });
  });
});
