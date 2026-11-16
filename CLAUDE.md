# CLAUDE.md

## Language

All code must be written in English: identifiers, comments, log and UI strings, script output, commit messages, and file names.

## Animation

All animations must be spring-based (e.g. `.spring`, `.snappy`, `.smooth`, `.bouncy`). Never use timing curves like `.easeInOut` or `.linear`.

## Visual rules

- Editorial and square: contemporary magazine, not newspaper. Sans type at normal desktop sizes; hierarchy comes from weight and spacing, not size. No serif headlines, columns or rules. Moderate, firm corners from `Theme.Radius`, never pills; rigid, structured shapes. Use the `Theme.Font` scale.
- Accent is sky blue (`Theme.accent`, hue ~208°), secondary is yellow/cream (`Theme.secondary`, `Theme.cream`). The blue must never drift toward teal or cyan; no green or teal anywhere in the palette, it reads as generic AI styling. Yellow is for details and highlights, never behind long text. Text on any fill must pass WCAG AA (`ThemeContrastTests`).
- Surfaces are borderless: separate them with fill, spacing and soft shadow, not strokes.
- Controls are well delimited: every button, chip, tab and accordion header gets its own clear area through a solid fill that contrasts with what is behind it and a crisp square shape. Strokes only where a fill can't do it (e.g. text fields).
- Panels and dialogs are paper: `Theme.paper` / `.paperSurface()`, a static grain generated once and tiled. The sidebar is translucent instead: the sky blurred behind a light paper tint (`SidebarBackdrop`). The canvas is the sky.
- No gradients: not on text, fills, or borders. Use solid colors from `Theme`.
- Ambient effects (smoke, glow, blooms) must always be animated, drifting slowly like moving smoke. Never leave one static. Paper grain is a material, not an ambient effect.
- All colors, radii and type sizes come from `Theme`; no hardcoded hex values in views.
- Never show the app name inside the app (headlines, eyebrows, labels). The window title is the only exception.

## UI copy

- Don't explain the product inside the product ("this app watches X and shows Y"). The user already chose it; that copy belongs to marketing.
- Do explain choices: every option, action, or card the user must pick between gets one short line saying what it does.
