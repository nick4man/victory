import { test, expect } from '@playwright/test';

test.describe('Catalog — /properties', () => {
  test('default catalog view (no filters)', async ({ page }) => {
    await page.goto('/properties');
    await page.waitForLoadState('networkidle');

    // Cards lazy-load — wait until first row is fully painted.
    const firstCard = page.locator('[data-property-card], .property-card').first();
    await firstCard.waitFor({ state: 'visible' });

    await expect(page).toHaveScreenshot('properties-index-default.png', {
      fullPage: true,
    });
  });

  test('filtered: sale + 2 rooms', async ({ page }) => {
    await page.goto('/properties?q[deal_type_eq]=sale&q[rooms_eq]=2');
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveScreenshot('properties-index-filtered.png', {
      fullPage: true,
    });
  });
});
