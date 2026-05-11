# Content slots for SEO landings

Files in this directory are partials rendered inside `landings/show.html.erb`.
They turn programmatically-generated landings into pages with editorial weight,
which is required for Google/Yandex to rank them (thin content gets demoted).

## File naming

The controller looks for partials in this order — the first match wins:

```
landings/content/{intent}_{type}_{district_or_rooms}.html.erb
landings/content/{intent}_{type}.html.erb
```

Where:
- `intent`   — `sale` or `rent`
- `type`     — `kvartira`, `dom`, `uchastok`, `komnata`, `kommercheskaya`
- `district` — latin slug from `DISTRICT_MAP` (e.g. `kanishchevo`)
- `rooms`    — `1`..`4` or `studiya`

## Examples

| URL | Looked up partials (in order) |
|---|---|
| `/kupit/kvartira` | `sale_kvartira.html.erb` |
| `/kupit/kvartira/2-komnatnaya` | `sale_kvartira_2.html.erb` → `sale_kvartira.html.erb` |
| `/kupit/kvartira/rayon/kanishchevo` | `sale_kvartira_kanishchevo.html.erb` → `sale_kvartira.html.erb` |
| `/snyat/dom` | `rent_dom.html.erb` |

## What goes inside

600-1500 words of unique copy that:
- explains the local market for this slice (price range, supply, demand)
- highlights what the user should consider (district infrastructure, school
  zones, transport, building stock age — whatever's relevant)
- includes a FAQ block (5-8 questions) — wrap it in
  `<details><summary>Q</summary>A</details>` so the page also gets
  Schema.org FAQPage eligibility (helper to be added).

No images are required — the listings grid below this section provides
visual weight.
