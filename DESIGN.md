# Design

Source of truth for tokens: `Sources/AgentBoard/UI/Theme.swift`.

## Identity

- **Light mode only.** The app pins `.aqua` appearance and `.preferredColorScheme(.light)`; never design dark variants.
- **Accent — violet `#6E56CF`:** actions, selection, focus, primary buttons (applied app-wide via `.tint`).
- **Secondary — orange `#F76B15`:** a warm complement to violet for supporting highlights. Use sparingly; never on the same element as the accent.
- **Canvas `#FBFAFF`:** white with a faint violet cast. Cards sit on it in pure white.
- **Lines:** violet-tinted ink (`#2E1F6B`) at low opacity, used for shadows and the rare required divider.

## Surfaces

- Main content is always a canvas. `canvas` mode: strong grid; `offCanvas`: faint grid (set in code).
- First run (no projects): no sidebar, off-canvas grid, slowly wandering violet and orange background lights, three large start cards (Start from scratch, Clone a repository, Open a folder), each with one line on what it does.
- Cards: 18pt radius, white, borderless, soft violet shadow, compact height (no empty filler); icon in a 64pt tinted badge, no stroke. Hover lifts with `.snappy`.

## Rules

- Borderless by default; fill, spacing, and shadow separate surfaces.
- No green or teal.
- No gradients anywhere. Solid `Theme` colors only.
- Ambient smoke/glow is allowed only when animated (slow drift and breathing, spring-based, `repeatForever`).
- The app name never appears inside the UI.
- Copy explains options (one line per choice), never the product itself.

## Motion

Spring-based only (`.snappy`, `.smooth`, `.spring`, `.bouncy`).
