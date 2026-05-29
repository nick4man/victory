# Visual regression — Playwright

6 spec файлов покрывают **7 ключевых пользовательских flow** на двух
viewport'ах (desktop 1440×900 + Pixel 7 mobile):

| Spec | Pages |
|---|---|
| `landing.spec.ts` | `/` (fullpage + hero closeup) |
| `property-show.spec.ts` | `/properties/:id` (uses SEED_PROPERTY_ID=1 by default) |
| `properties-index.spec.ts` | `/properties` (default + filtered) |
| `articles-index.spec.ts` | `/news` |
| `mortgage-calc.spec.ts` | `/services/mortgage` |
| `contacts.spec.ts` | `/contacts` |
| `valuation.spec.ts` | `/valuations` (empty form + filled form) |

## Activation (one-time)

```bash
# 1. Install dev npm tools (Figma + Playwright share package.json)
npm install

# 2. Install Playwright browsers (~300 MB)
npx playwright install --with-deps chromium

# 3. Generate the FIRST set of baselines.
#    Rails dev server должен быть запущен — обычно уже работает в
#    victory-сессии на :3000. Если нет — `bin/rails server -p 3000`.
npm run vr:update

# 4. Review the diff (git diff tests/visual/__screenshots__/...)
#    Все PNG'и закоммитьте — это и есть visual contract.
git add tests/visual/__screenshots__
git commit -m "test(visual): initial Playwright VR baselines"
```

## Regular usage

После любых правок в views / partials / Tailwind / Stimulus:

```bash
npm run vr:test
```

Если упадёт — откройте `playwright-report/` или передайте `--ui`:

```bash
npm run vr:ui     # interactive UI с side-by-side diff
```

Решите — это **regression** (фикснуть) или **intentional design change**
(обновить baseline):

```bash
npm run vr:update
git diff tests/visual/__screenshots__/...   # глазами проверьте diff
git add ...
git commit
```

## Config knobs (`playwright.config.ts`)

- **`PLAYWRIGHT_BASE_URL`** — override (по умолчанию `http://localhost:3000`)
- **`SEED_PROPERTY_ID`** — какой Property ID использовать для show-spec (default 1)
- **`maxDiffPixelRatio: 0.02`** — 2% pixel tolerance до объявления regression
- **`animations: 'disabled'`** — все CSS transitions замораживаются на screenshot

## Что входит в baseline (закоммичено)

```
tests/visual/__screenshots__/
  landing.spec.ts/
    landing-fullpage-desktop-chrome.png
    landing-fullpage-mobile-chrome.png
    landing-hero-desktop-chrome.png
    landing-hero-mobile-chrome.png
  property-show.spec.ts/...
  ...
```

**Не** в baseline (gitignored):
- `test-results/` — diff PNGs, generated on failure
- `playwright-report/` — HTML report
- `playwright/.cache/` — internal cache

## Masking — что прячем от сравнения

Маскированные через `mask: [page.locator(...)]` элементы:
- Photo gallery PhotoSwipe (lazy-loads, animation timing вариативен)
- Yandex Map canvas (tiles between requests differ)
- Bank rate values (BankRateSnapshot meняется live)
- News carousel active slide (auto-rotates)

Pattern: маскируем **значения**, оставляем **layout** в сравнении.

## CI integration (future, not enabled)

Когда понадобится — добавить новый job в `.github/workflows/`:

```yaml
visual-regression:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-node@v4
      with: { node-version: '20' }
    - run: npm ci
    - run: npx playwright install --with-deps chromium
    # Запустить Rails… (зависит от инфры — db setup, seeds, etc.)
    - run: npm run vr:test
    - if: failure()
      uses: actions/upload-artifact@v4
      with: { name: playwright-report, path: playwright-report/ }
```

## Связанные доки

- `.claude/skills/figma-to-erb-handoff/SKILL.md` — workflow когда Figma
  design landing меняет компонент — VR ловит layout shift
- `playwright.config.ts` — root config
- `.figma/code-connect/` — design-side контракт
