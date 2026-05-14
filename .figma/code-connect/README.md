# Figma Code Connect — victory62

Maps Figma design components → ERB partial snippets, so the Figma MCP
server returns Rails-flavoured code (not its default React) when an
agent calls `figma:figma-implement-design`.

## Activation steps (one-time)

```bash
# 1. Install npm dev-tools (Figma + Playwright share this package.json)
npm install

# 2. Authenticate with your Figma account (interactive — opens browser)
npx code-connect login

# 3. Set FIGMA_ACCESS_TOKEN in your shell env (or ~/.zshenv) —
#    needed for non-interactive `code-connect publish` later.
#    Generate at: https://www.figma.com/settings → Personal access tokens
export FIGMA_ACCESS_TOKEN='figd_...'

# 4. Open each template under .figma/code-connect/templates/*.figma.js
#    and replace the placeholder Figma URL (<FILE_KEY>/<NODE_ID>) with
#    the real one from your design file.

# 5. Publish mappings to Figma
npm run figma:publish
```

After publish, the Figma MCP tool `mcp__figma__*` (if connected) returns
ERB snippets for the mapped nodes.

## Template files

| File | Maps to | Lives in |
|---|---|---|
| `button.figma.js` | "Button" component (3 variants × 3 sizes) | inline `<%= link_to %>` with Tailwind classes |
| `property-card.figma.js` | "Property Card" | `render 'properties/property_card'` partial |
| `callback-modal.figma.js` | "Callback Modal" | `render 'shared/callback_modal'` partial |
| `news-carousel.figma.js` | "News Carousel" | `render 'shared/news_carousel'` partial |

Add more templates as designs land. Pattern: each component = one
`.figma.js` file under `templates/`.

## Why this approach

Figma Code Connect was built for React/Vue/SwiftUI/Compose — not ERB.
Two workarounds are in play:

1. **`parser: "html"`** in `figma.config.json` — Code Connect treats the
   `example` function's return value as raw HTML/template string.
2. **Partial-call snippets** for complex components — instead of inlining
   the full markup in the template (would drift from the actual partial),
   templates emit `<%= render 'shared/...' %>` calls. The Figma viewer
   shows the partial path, the agent reads the partial file when it
   needs the inner markup.

## Connected docs

- `.claude/skills/figma-to-erb-handoff/SKILL.md` — workflow used by Claude
- `.figma/code-connect/templates/*.figma.js` — actual mappings
- `app/views/shared/` — partial source (20+ files including site_header,
  site_footer, chat_widget, callback_modal, news_carousel, …)
- `tailwind.config.js` — design tokens (palette, shadows, animations)
  that Figma should mirror

## Updating mappings

When a design change lands:

```bash
# Pull latest Figma file metadata
npx code-connect refresh

# Edit relevant *.figma.js (props, variants, example)

# Re-publish
npm run figma:publish
```

Lint Code Connect mappings: `npx code-connect lint`.
