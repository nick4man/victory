import { test, expect } from '@playwright/test';

test.describe('Mortgage calculator — /services/mortgage', () => {
  test('calculator form + bank rates table', async ({ page }) => {
    await page.goto('/services/mortgage');
    await page.waitForLoadState('networkidle');

    // The rate table is the highest-value visual contract — banks/rates
    // change but the table layout shouldn't shift.
    await expect(page).toHaveScreenshot('mortgage-calc.png', {
      fullPage: true,
      mask: [
        // Rate cells contain live numbers from BankRateSnapshot — mask
        // the value column. Layout of cells + table headers is asserted.
        page.locator('[data-rate-value], .bank-rate-value'),
      ],
    });
  });
});
