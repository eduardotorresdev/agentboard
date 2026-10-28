# CLAUDE.md

## Language

All code must be written in English: identifiers, comments, log and UI strings, script output, commit messages, and file names.

## Animation

All animations must be spring-based (e.g. `.spring`, `.snappy`, `.smooth`, `.bouncy`). Never use timing curves like `.easeInOut` or `.linear`.

## Visual rules

- Borderless by default: separate surfaces with fill, spacing, and soft shadow, not strokes. Use a border only where a control needs one to read as interactive (e.g. text fields).
- No green or teal anywhere in the palette; it reads as generic AI styling. Accent is violet, secondary is orange.
- No gradients: not on text, fills, or borders. Use solid colors from `Theme`.
- Ambient effects (smoke, glow, blooms) must always be animated, drifting slowly like moving smoke. Never leave one static.
- Never show the app name inside the app (headlines, eyebrows, labels). The window title is the only exception.

## UI copy

- Don't explain the product inside the product ("this app watches X and shows Y"). The user already chose it; that copy belongs to marketing.
- Do explain choices: every option, action, or card the user must pick between gets one short line saying what it does.
