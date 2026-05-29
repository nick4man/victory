import { test, expect } from '@playwright/test';

// Visual regression for the canonical property show page. Uses ID=1
// which is seeded to a representative listing — change SEED_PROPERTY_ID
// in your env if your dev DB has different data.
const SEED = process.env.SEED_PROPERTY_ID || '1';

test.describe('Property show — /properties/:id', () => {
  test('hero + gallery + meta + sidebar', async ({ page }) => {
    await page.goto(`/properties/${SEED}`);
    await page.waitForLoadState('networkidle');

    await expect(page).toHaveScreenshot('property-show-fullpage.png', {
      fullPage: true,
      mask: [
        // Photo gallery uses PhotoSwipe which lazy-loads on scroll —
        // animations vary slightly. Mask the gallery container; assert
        // its presence implicitly via the surrounding layout.
        page.locator('.pswp__container'),
      ],
    });
  });
});
