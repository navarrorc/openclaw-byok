---
name: website-design
description: Use whenever generating a self-contained HTML page to publish via publish_website or /website — makes it look like a real, professional product instead of plain unstyled HTML.
metadata: { "openclaw": { "always": true } }
---

# Website design

`publish_website` and `/website` ship whatever HTML you hand them, byte for
byte. There is no template, no CSS pipeline, no reviewer in between — a plain
`<h1>` and unstyled `<div>`s go out exactly as plain and unstyled as they were
written. Treat every page as a real product surface, not a scratch note.

## Decide the look, in this order

1. **The user specified a look, brand, or reference.** Follow it. Their
   explicit ask always outranks anything below.
2. **Otherwise, use the system in this file.** Never fall back to bare
   unstyled HTML — a page with no design system is the failure mode this
   skill exists to prevent.

## The stack: Tailwind v4 + DaisyUI v5, zero build step

This is a single self-contained HTML file with no bundler, so pull both in
as CDN `<link>`/`<script>` tags in `<head>`. Paste this exactly:

```html
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/daisyui.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5.5.19/themes.css">
<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.2.4/dist/index.global.js"></script>
```

Tailwind's browser build compiles utility classes live in the page, and
DaisyUI layers real component classes (`btn`, `card`, `navbar`, ...) on top —
together they turn raw markup into something that looks designed, with no
separate build step this plugin doesn't have anyway.

## Pick a theme, then use semantic classes

Set `<html data-theme="...">`. Default to **`luxury`** unless the request
points somewhere else. A few other good fits by vibe:

- `corporate` — clean SaaS/dashboard, safe default for internal tools
- `business` — dark, dense, data-heavy admin panels
- `forest` / `night` — dark developer-tool aesthetic
- `cupcake` / `pastel` — friendly, consumer-facing, lighter tone
- `winter` — crisp light theme when `luxury` reads too heavy

Then reach for DaisyUI's **semantic** color classes (`bg-base-100`,
`bg-base-200`, `text-base-content`, `btn-primary`, `badge-secondary`,
`alert-success`, ...) instead of hardcoded Tailwind colors (`bg-slate-800`,
`text-gray-300`). Semantic classes repaint correctly if the theme changes;
hardcoded colors don't and usually clash with whichever theme you picked.

## Layout-safety CSS — paste this every time

The single most common way a generated page "looks broken" is horizontal
overflow on a phone: a nested flex/grid child refusing to shrink below its
content width. Put this in `<head>` on every page, no exceptions:

```html
<style>
  *, *::before, *::after { box-sizing: border-box; }
  :where(.grid, .flex) > * { min-width: 0; }
  :where(p, h1, h2, h3, h4, li, td, th) { overflow-wrap: anywhere; }
  :where(img, svg, video, canvas, iframe) { max-width: 100%; height: auto; }
</style>
```

## Reach for real components, not bare tags

A plain `<button>` and `<div>` is exactly the "plain and not professional"
failure this skill exists to fix. Use DaisyUI's actual components instead —
these are the ones that carry the most visual weight per line of markup:

- **Buttons** — `btn btn-primary` / `btn-outline` / `btn-ghost`, sized with
  `btn-sm`/`btn-lg`
- **Cards** — `card bg-base-100 shadow-xl` with `card-body`, `card-title`,
  `card-actions` for any grouped content block, not just literal products
- **Stats** — `stats` + `stat`/`stat-title`/`stat-value`/`stat-desc` for any
  dashboard number instead of a bare styled `<div>`
- **Tables** — `table` (+ `table-zebra` for readability) for any tabular data
- **Forms** — `input input-bordered`, `select select-bordered`,
  `label`/`fieldset`, `textarea textarea-bordered`
- **Navbar** — `navbar bg-base-100` as the page header on anything with more
  than one section
- **Hero** — `hero` + `hero-content` for a landing page's top section
- **Alerts** — `alert alert-info`/`alert-success`/... for status/feedback
  messages instead of plain colored text

## Visual quality checklist

- **Hierarchy** — one clear "most important thing" per screen, made obvious
  by size/weight/color, not five equally-loud headings.
- **Whitespace** — generous padding/gaps (`p-6`, `gap-4`, `space-y-6`
  territory). Content crammed edge-to-edge reads as unfinished, not dense.
- **One color story** — pick the theme, then 1–2 accent colors used via
  `-primary`/`-secondary`/`-accent` classes. Don't hand-mix extra hues on top.
- **Mobile-first, always** — this is a link opened from Telegram, primarily
  on a phone. Design and mentally check the layout at **~390px wide** as the
  primary target, not desktop. Stack columns (`flex-col md:flex-row`,
  `grid-cols-1 md:grid-cols-3`) rather than assuming room for a wide layout.
