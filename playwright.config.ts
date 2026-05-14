// Playwright visual regression config for victory62 (Phase 2E).
//
// Targets the local Rails dev server (default http://localhost:3000).
// Override via PLAYWRIGHT_BASE_URL for staging / preview deploys.
//
// Snapshots live in tests/visual/__screenshots__/ and ARE committed to
// git — they are our visual contract. Diffs go to test-results/ which
// IS gitignored.
//
// Run:
//   npm run vr:test           — verify against committed baselines
//   npm run vr:update         — regenerate baselines (after intentional
//                               design changes; review the diff before
//                               committing)
//   npm run vr:ui             — interactive Playwright UI

import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests/visual',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? 'github' : 'list',

  // Screenshots compare against committed PNG baselines. 0.2 pixel
  // tolerance is the Playwright default — generous enough to ignore
  // font-rendering nits, strict enough to catch real layout shifts.
  expect: {
    toHaveScreenshot: {
      maxDiffPixelRatio: 0.02,
      threshold: 0.2,
      animations: 'disabled',
    },
  },

  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL || 'http://localhost:3000',
    locale: 'ru-RU',
    timezoneId: 'Europe/Moscow',
    // Cyrillic-friendly font fallback chain — matches what the prod
    // browser would render given the Inter Google Font + system-ui.
    extraHTTPHeaders: {
      'Accept-Language': 'ru-RU,ru;q=0.9',
    },
    actionTimeout: 10_000,
    navigationTimeout: 30_000,
  },

  projects: [
    {
      name: 'desktop-chrome',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1440, height: 900 },
      },
    },
    {
      name: 'mobile-chrome',
      use: {
        ...devices['Pixel 7'],
      },
    },
  ],

  // Don't launch the Rails server from Playwright — assumes it's already
  // up on :3000 (which it is in the victory session). If you want
  // ephemeral start-stop, uncomment and adjust:
  //
  // webServer: {
  //   command: 'bin/rails server -p 3000',
  //   url: 'http://localhost:3000',
  //   reuseExistingServer: true,
  //   timeout: 120_000,
  // },
});
