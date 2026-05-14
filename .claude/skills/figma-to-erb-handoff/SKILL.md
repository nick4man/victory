---
name: figma-to-erb-handoff
description: Use when implementing a design from Figma into the victory62 codebase (ERB + Tailwind). Establishes the workflow with figma MCP tools (figma-use, figma-implement-design), maps Figma components to existing shared/partials, ensures Tailwind design tokens stay synchronized, and avoids common Figma→React drift in favor of ERB output.
---

# Figma → ERB+Tailwind handoff

## When to use

- New design lands в Figma (header/page/component), нужно реализовать в victory62
- Update existing component когда дизайн меняется
- Извлечь design tokens из Figma в `tailwind.config.js`

## Stack mismatch you'll face

Figma MCP по умолчанию ориентирован на **React/Next.js + Tailwind**. Victory62 — **ERB + Tailwind + Stimulus + Importmap**, без React.

**Что это значит**:
- Не получишь `.tsx` готовые snippets — нужна конверсия в `.erb`
- Component composition в ERB через partials, не через React `<Component />`
- Interactivity через Stimulus controllers (`data-controller`, `data-action`), не через `onClick`

## Pre-requisites (one-time setup — Phase 2D scaffolded; you активируете)

Scaffolding закоммичен в репозитории (Phase 2D). Активация:

```bash
# 1. npm dev-tools (Figma + Playwright shared package.json)
npm install

# 2. Auth с вашим Figma аккаунтом
npx code-connect login

# 3. Persistent token в shell env
#    Generate: https://www.figma.com/settings → Personal access tokens
export FIGMA_ACCESS_TOKEN='figd_...'

# 4. Заменить placeholder Figma URLs в templates на реальные
#    .figma/code-connect/templates/{button,property-card,callback-modal,news-carousel}.figma.js
#    — поменять <FILE_KEY>/<NODE_ID> на копированный URL из Figma

# 5. Опубликовать mappings
npm run figma:publish
```

После step 5: Figma MCP `mcp__figma__*` (если подключён) начнёт возвращать ERB-snippets для mapped node'ов вместо React. Подробности — `.figma/code-connect/README.md`.

**Текущий state**: scaffolding есть, mappings — placeholder. Можно работать без Code Connect: Figma MCP вернёт React, вы конвертируете в ERB по таблице ниже.

## Available tools (skill-namespace `figma:`)

| Tool | Purpose | When |
|---|---|---|
| `figma:figma-use` | **MANDATORY prerequisite** для `use_figma` вызова | Перед любым write/read в Figma |
| `figma:figma-implement-design` | Translate Figma → production code | Реализация компонента |
| `figma:figma-generate-design` | Reverse — code → Figma | Если хочется Figma из существующего ERB |
| `figma:figma-code-connect` | Setup Code Connect mappings | One-time Phase 2D |
| `figma:figma-create-design-system-rules` | Generate project-specific design rules | One-time setup |
| `figma:figma-generate-library` | Build/update design system in Figma | Когда меняется token set |
| `figma:figma-implement-design` | 1:1 visual fidelity translation | Main workflow |

## Workflow (без Code Connect — Phase 2A)

### Step 1: Получи Figma design URL + наш context

User присылает Figma frame URL + что хочется (header / property card / hero / form / etc.).

### Step 2: Прочти design через Figma MCP

```
figma:figma-implement-design (frame URL)
```

Получишь:
- Auto-layout structure
- Spacing/padding values
- Colors / typography
- Hover/focus states (если в дизайне)

### Step 3: Map в наш стек

Конвертация React-style → ERB:

| Figma/React output | ERB equivalent |
|---|---|
| `<div className="flex gap-4">` | `<div class="flex gap-4">` (`className → class`) |
| `<Button variant="primary">Купить</Button>` | `<%= link_to 'Купить', '#', class: 'btn-primary' %>` |
| `onClick={...}` | `data-controller="..." data-action="click->..."` |
| `<Image src=...>` | `<%= image_tag image_path, alt: '...' %>` |
| `<Input value={x} onChange={...}>` | Rails form helpers + Stimulus |
| Custom color `#3b82f6` | Tailwind class (см. `tailwind.config.js` palette) |

### Step 4: Найди существующий partial

Перед тем как создавать новое — посмотри в `app/views/shared/`:

```bash
ls app/views/shared/   # 18 partials
```

Уже есть: `_chat_widget`, `_news_carousel`, `_callback_modal`, `_dashboard_nav`, `_site_header/footer`, `_address_autocomplete`, `_article_card/modal`, `_reviews_strip`, и др.

**Если похожее есть** — extend/modify, не создавай дубль.

### Step 5: Создай/обнови partial

```erb
<%# app/views/shared/_property_hero.html.erb %>
<%# Usage: render 'shared/property_hero', property: @property %>
<section class="relative bg-primary-50 py-12">
  <div class="container mx-auto px-4">
    <div class="grid lg:grid-cols-2 gap-8 items-center">
      <div>
        <h1 class="text-3xl lg:text-4xl font-bold text-secondary-900">
          <%= property.title %>
        </h1>
        <p class="mt-4 text-lg text-secondary-700">
          <%= property.price_formatted %>
        </p>
      </div>
      <div>
        <%= image_tag property.images.first, alt: property_image_alt(property),
                      class: 'rounded-2xl shadow-medium w-full' %>
      </div>
    </div>
  </div>
</section>
```

### Step 6: Использовать tokens из tailwind.config.js

Не хардкодь HEX-значения в classes. У нас уже:

- **Colors**: `primary` (50-950), `secondary`, `success`, `danger`, `warning`
- **Shadows**: `shadow-soft`, `shadow-medium`, `shadow-strong`, `shadow-inner-soft`
- **Animations**: `animate-fade-in`, `animate-slide-in-*`, `animate-bounce-in`
- **Z-index**: 60-100 custom scale
- **Fonts**: Inter (Google Fonts)

Если в Figma color которого нет — **сначала добавь в `tailwind.config.js`** (через token), потом используй class. НЕ хардкодь `style="color: #abc123"`.

### Step 7: Interactivity → Stimulus

Если в дизайне есть hover/expand/modal/dropdown — реализуй через Stimulus:

```erb
<div data-controller="property-card"
     data-property-card-id-value="<%= property.id %>">
  <button data-action="property-card#toggleFavorite">
    <%= heart_icon class: 'w-6 h-6' %>
  </button>
</div>
```

```js
// app/javascript/controllers/property_card_controller.js
import { Controller } from '@hotwired/stimulus'
export default class extends Controller {
  static values = { id: Number }
  toggleFavorite() {
    // ...
  }
}
```

### Step 8: Validate

- Lighthouse SEO + a11y score через `mcp__plugin_chrome-devtools-mcp__lighthouse_audit`
- Manual: open in browser, проверь mobile (Chrome devtools → device emulation)
- Screenshot и сравни с Figma (eyeball regression)

## Anti-patterns

- ❌ Копировать React jsx as-is в ERB — нужна конверсия
- ❌ Хардкодить HEX colors — всё через Tailwind classes / config
- ❌ Inline `style="..."` — мы боремся с этим (108 случаев на проекте)
- ❌ Создавать новый partial если похожее уже есть в `shared/`
- ❌ Tailwind class дублирование (`flex items-center justify-between` × 38 раз) — выдели в `.card-header` через `@apply`
- ❌ Игнорировать dark mode — config есть, но classes 0; постепенно добавляй `dark:` варианты для новых компонент

## Tools you'll use together

- `figma:figma-use` (mandatory предусловие)
- `figma:figma-implement-design`
- `mcp__serena__find_symbol` для существующих partials
- `Read` / `Edit` / `Write` для ERB файлов
- `Bash bundle exec rails server` для preview (в victory-сессии)

## Session-split note

Дизайн-имплементация — **victory-сессия** (Rails dev-server preview). В chat-сессии можно только проводить инвентаризацию Figma и планировать.

## Future: Code Connect (Phase 2D)

Когда добавим `.figma/code-connect.config.json` с `language: erb` и mappings типа:

```ts
import figma from '@figma/code-connect'
figma.connect(
  'https://figma.com/.../button',
  {
    erb: '<%= link_to props.label, "#", class: "btn-primary" %>'
  }
)
```

Figma MCP сможет возвращать ERB напрямую без ручной конверсии.

## When to call this skill

- При импорте Figma frame в victory
- При создании нового layout-section
- При unifying tokens between Figma и Tailwind config
