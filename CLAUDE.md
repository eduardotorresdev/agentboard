# CLAUDE.md

## Language

All code must be written in English: identifiers, comments, log and UI strings, script output, commit messages, and file names.

Talk to the user in Brazilian Portuguese (pt-BR): replies, questions and summaries.

## Animation

All animations must be spring-based (e.g. `.spring`, `.snappy`, `.smooth`, `.bouncy`). Never use timing curves like `.easeInOut` or `.linear`.

## Visual rules

- Editorial: contemporary magazine, not newspaper. Sans type at normal desktop sizes; hierarchy comes from weight and spacing, not size. No serif headlines, columns or rules. Moderate, firm corners from `Theme.Radius`. This applies to cards, dialogs, the sidebar and content buttons. Chrome that uses native Liquid Glass (top bar controls, canvas toolbars, the agent composer) keeps the system glass and its round/capsule shapes. Never remove rounding without the user asking for it. Use the `Theme.Font` scale.
- Palette: white, light grays, near-white baby blue, a solid blue and near-black, taken from Radix Colors (Slate and Blue light scales) through `Theme`. `Theme.accent` (Blue 11) is for primary actions, focus, selection and running; `Theme.deep` (Blue 12) for strong emphasis and "waiting for you"; red (`Theme.danger`) only for errors. No yellow, green or teal; the blue must never drift toward teal or cyan. Text on any fill must pass WCAG AA (`ThemeContrastTests`).
- Surfaces are borderless: separate them with fill, contrast and spacing, not strokes. No shadows on board elements (cards, composer, badges, canvas toolbars, focused cards): their contrast against the sky is enough. Where something truly needs separation, at most one short discreet shadow (`Theme.Shadow`), never a wide blurred one.
- Controls are well delimited: every button, chip, tab and accordion header gets its own clear area through a solid fill that contrasts with what is behind it and a firm, moderately rounded shape (glass chrome excepted, see above). Strokes only where a fill can't do it (e.g. text fields).
- Panels and dialogs are white or light gray (`Theme.surface`, `Theme.surfaceDeep`). The window top bar is white. The canvas is the sky.
- Card headers are translucent, blurring the sky behind them. The agent composer uses Liquid Glass.
- No gradients: not on text, fills, or borders. Use solid colors from `Theme`.
- Ambient effects (smoke, glow, blooms) must always be animated, drifting slowly like moving smoke. Never leave one static.
- All colors, radii and type sizes come from `Theme`; no hardcoded hex values in views. Exception: brand icons keep their brand colors (Claude orange, Codex), as logos, and so do syntax-highlighting colors and the terminal ANSI palette.
- Never show the app name inside the app (headlines, eyebrows, labels). The window title is the only exception.

## UI copy

- Don't explain the product inside the product ("this app watches X and shows Y"). The user already chose it; that copy belongs to marketing.
- Do explain choices: every option, action, or card the user must pick between gets one short line saying what it does.
- Never tie UI copy to a specific provider; say agent. Provider names appear only where the user picks or must tell providers apart (creating an agent, naming its card, per-provider sections, "not installed" errors), and always come from the catalog (`AgentProvider.title`), never hand-written into a sentence.
