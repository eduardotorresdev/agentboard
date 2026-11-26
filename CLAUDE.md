# CLAUDE.md

## Language

All code must be written in English: identifiers, comments, log and UI strings, script output, commit messages, and file names.

Talk to the user in Brazilian Portuguese (pt-BR): replies, questions and summaries.

## Animation

All animations must be spring-based (e.g. `.spring`, `.snappy`, `.smooth`, `.bouncy`). Never use timing curves like `.easeInOut` or `.linear`.

## Visual rules

- Grafite: the app is dark only. Near-black planes stacked by lightness: `Theme.window` (window, top bar) < `Theme.plane` (sidebar) < `Theme.canvas`/`Theme.sky` (canvas, with a faint dot grid) < `Theme.surface` (cards, panels, dialogs, popovers) < `Theme.surfaceDeep` (controls, card headers, wells).
- Editorial: contemporary magazine, not newspaper. Sans type at normal desktop sizes; hierarchy comes from weight and spacing, not size. No serif headlines, columns or rules. Soft continuous (squircle) corners from `Theme.Radius`, always `style: .continuous`. This applies to cards, dialogs, the sidebar and content buttons. Never remove rounding without the user asking for it. Use the `Theme.Font` scale.
- Palette: the graphite planes, light ink (`Theme.ink`, `Theme.inkMuted`, `Theme.faint`), one strong blue and amber. `Theme.accent` is for primary actions, focus, selection and running (as a fill with white text; as text or a small mark on dark use `Theme.accentText`); `Theme.accentSoft` for selected rows; `Theme.deep` (pale blue) for strong emphasis; `Theme.you` (amber, `Theme.onYou` text) only for "waiting for you"; red (`Theme.danger`) only for errors. Caffeinate's on state uses the coffee pack's maroon (`Theme.caffeinate`). No green or teal; the blue must never drift toward teal or cyan. Text on any fill must pass WCAG AA (`ThemeContrastTests`).
- Surfaces are borderless: separate them with fill, contrast and spacing, not strokes. No shadows on board elements (cards, composer, badges, canvas toolbars, focused cards). Where something truly needs separation, at most one short discreet shadow (`Theme.Shadow`), never a wide blurred one.
- Controls are well delimited: every button, chip, tab and accordion header gets its own clear area through a solid fill that contrasts with what is behind it and a firm, softly rounded shape. A toggle's fill is its state (on = filled with its color); no separate switch. Strokes only where a fill can't do it (e.g. text fields, a focused control's accent ring).
- No gradients: not on text, fills, or borders. Use solid colors from `Theme`.
- Ambient effects (smoke, glow, blooms) must always be animated, drifting slowly like moving smoke. Never leave one static.
- All colors, radii and type sizes come from `Theme`; no hardcoded hex values in views. Exception: brand icons keep their brand colors (Claude orange, Codex), as logos, and so do syntax-highlighting colors and the terminal ANSI palette.
- Never show the app name inside the app (headlines, eyebrows, labels). The window title is the only exception.

## UI copy

- Don't explain the product inside the product ("this app watches X and shows Y"). The user already chose it; that copy belongs to marketing.
- Do explain choices: every option, action, or card the user must pick between gets one short line saying what it does.
- Never tie UI copy to a specific provider; say agent. Provider names appear only where the user picks or must tell providers apart (creating an agent, naming its card, per-provider sections, "not installed" errors), and always come from the catalog (`AgentProvider.title`), never hand-written into a sentence.
