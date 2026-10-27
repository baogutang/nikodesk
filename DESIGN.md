# Design: NikoDesk

The locked system for NikoDesk 3.0. Every Hallmark run reads this first, and the app and the website share it. Change it on purpose: the file is the rule. The comps that set it are in `design/app-3.0/` (open `index.html`).

## System
- Genre: modern-minimal
- Shape of the first page: app screen (home: this computer's code beside the field for the other one, recent connections below)
- Theme: brand (the logo blue; the user asked to keep the logo and name, to drop the generated look, and to take ToDesk's plain, familiar layout as the reference)
- Axes: light/grotesk-sans/chromatic-blue · posture: restrained · modes: light+dark

## Tokens
`design/app-3.0/tokens.css` is the source of truth; the Flutter tokens are generated from it. The roles:
```css
:root {
  --color-paper: oklch(99.3% 0.002 259);  --color-paper-2: oklch(97.2% 0.004 259);  --color-paper-3: oklch(94.6% 0.006 259);
  --color-ink: oklch(23% 0.014 259);  --color-ink-2: oklch(45% 0.014 259);  --color-muted: oklch(57% 0.012 259);  --color-rule: oklch(91.5% 0.006 259);
  --color-edge: oklch(84% 0.008 259);
  --color-accent: oklch(56.5% 0.215 259);  --color-accent-ink: oklch(99.3% 0.002 259);  --color-focus: oklch(58% 0.2 259);
  --color-accent-soft: oklch(95.2% 0.03 259);  --color-accent-text: oklch(52% 0.2 259);
  --color-error: oklch(52% 0.19 27);  --color-success: oklch(50% 0.12 150);  --color-warning: oklch(52% 0.11 70);
  --font-display: the platform's own face (PingFang SC and SF Pro, Segoe UI and Microsoft YaHei UI, Noto Sans SC);  --font-body: the same;
  --color-canvas: oklch(96.2% 0.007 259);  --color-surface: oklch(99.6% 0.0015 259);
  --radius-card: 10px;  --radius-control: 6px;  --radius-tag: 4px;  --rule-hair: 1px;
  --shadow-card: 0 1px 2px oklch(23% 0.014 259 / 0.06), 0 0 0 1px oklch(23% 0.014 259 / 0.06);
}
```
Dark mode re-derives every token (`tokens.css`, `[data-mode="dark"]`); the dark accent fill stays at L 55% so white text keeps 4.5:1, and surfaces sit lighter than the canvas with an inset ring instead of a shadow. Type roles: page title 22, panel title 24, section 17, card and body 14 to 15, label 13, caption 12; this computer's code 34 with tabular figures, one step up on touch; buttons are 32px and 48px (40px and 52px on touch).

## Rules the app follows
- One accent, as a signal: the primary action, the current place, focus. Never device colours, never gradients, never glow.
- One committed surface: the home connect panel in `--color-brand` (logo blue, L 50.5%; L 37% in dark) with white type, white field and a white split button whose label is the panel blue. It is the first thing on the home screen because connecting is the main task. Nothing else is filled with blue.
- The session toolbar is a dark HUD (`--color-hud*`) in both modes, because it floats over any remote picture. Status chips on pictures are dark (`--color-chip-dark`).
- Status pills (`.pill`) pair a soft tint with its own ink: success for ready, warning for something missing.
- Surfaces: the window is a tinted canvas (`--color-canvas`); every block of content sits on one raised surface (`--color-surface` with `--shadow-card`, an inset ring in dark mode). Menus, dialogs and the session toolbar take `--shadow-pop`.
- Devices are shown by their last screen (16:10, 6px radius) with a live-state chip; a device without a picture says why (no screen, never connected, controller only). Offline screens go grey.
- Data lists that compare are tables; devices are tiles on the home screen and a list beside a detail panel on the devices screen.
- Device icons are monochrome line icons from one set; platform names are text.
- Labels are sentence case in the body face; no eyebrows, no middle-dot strings, no tracked capitals. A dot appears only as a live state.
- Every region that loads data draws loading, empty, error and full.
- Motion is state only: 120 and 220ms, transform and opacity; reduced motion ends at once.

## Controls
- Primary: accent fill · 6px radius · 32px (48px in the connect row)
- Secondary: paper with a 1px edge · same radius and height; quiet: text only

## Motion
- Character: brisk; no reveal; a tile lifts 1px on hover; under reduced motion everything ends at once.

## Exports
`design/app-3.0/tokens.css`. The Flutter mapping lives in `flutter/lib/nikodesk/nightline/tokens.dart`.
