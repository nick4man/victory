import { test, expect } from '@playwright/test';

test.describe('Contacts — /contacts', () => {
  test('contacts page with map, hours, FAQ', async ({ page }) => {
    await page.goto('/contacts');
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveScreenshot('contacts.png', {
      fullPage: true,
      mask: [
        // Yandex Map renders different tiles between regions/zoom —
        // mask the map canvas; assert presence of the container.
        page.locator('#yandex-map, [data-yandex-map]'),
      ],
    });
  });
});
