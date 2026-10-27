# ScreenGuard UI Design System

The UI follows a Samsung Digital Wellbeing / One UI-inspired Material 3 look:
soft rounded cards, generous spacing, a calm teal accent, and one clear hero
metric per screen. This document explains the shared primitives so future
screens (including Android phone and Android TV targets) stay consistent.

## Layout primitives

| File | Purpose |
| --- | --- |
| `lib/theme/app_theme.dart` | `AppTheme.light()` / `AppTheme.dark()`, `AppSpacing`, `AppRadius`, `AppPalette` |
| `lib/ui/adaptive.dart` | `AppLayout`, `AppScrollView`, `AppContent`, `MainShellScope` |
| `lib/widgets/app_section.dart` | `AppPageHeader`, `AppSectionCard`, `AppSectionHeader`, `AppStatTile`, `AppInfoBanner` |
| `lib/widgets/screen_time_ring.dart` | Animated circular gauge used for the hero metric |

`AppLayout.of(context)` resolves one of three window classes:

- **compact** `< 700 px` – phones, small desktop windows
- **medium** `700–1099 px` – tablets, narrow desktop windows
- **expanded** `>= 1100 px` – desktop and TV

Use `AppScrollView` for page content: it applies the responsive padding and a
readable max width automatically. Use `AppSectionCard` instead of raw `Card`
so radii, elevation and padding stay consistent.

## Navigation

`MainShell` owns four destinations: **Today**, **Focus**, **Reports** and
**Settings**.

- compact windows get a `NavigationBar` at the bottom (phone-friendly)
- medium/expanded windows get a `NavigationRail` (extended when expanded)

Screens can switch tabs through `MainShellScope.maybeOf(context)?.goToTab(i)`.

## Colour rules

Prefer `Theme.of(context).colorScheme` and `AppPalette.of(context)` over literal
colours. `AppPalette` provides chart hues, `idle`, `success`, `warning`,
`danger` and `breakTime`, all with light/dark variants.

## Android / TV readiness

The foundation already supports the main portability requirements:

- **No fixed widths or heights** for page content; breakpoints drive layout.
- **Bottom navigation on phones, rail on larger screens.**
- **D-pad awareness**: `AppLayout.isTv` is true when the platform reports
  `NavigationMode.directional`. Use it to enlarge targets or change layout.
- **Material 3 tap targets** (44–48 px minimum) are set in the theme.
- **ThemeExtension-based palette** so dynamic colour (Material You) can be
  supplied later without touching screen code.

When adding TV-specific behaviour, prefer:

1. Overscan-safe padding in `AppLayout.pagePadding`.
2. `FocusableActionDetector`/`InkWell` for any card the user can activate.
3. Visible focus styling (the Material widgets already do this).
4. Avoiding hover-only affordances and tiny text.
