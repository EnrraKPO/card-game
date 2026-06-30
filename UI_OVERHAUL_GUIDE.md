# UI Overhaul — Continuation Guide

A working guide to finish the screen-by-screen UI layout pass. Read this first, then `~/.claude` memory `button-sizing`.

## The point (don't relitigate this)
Every full-screen menu must **fill the screen with big, chunky, proportionally-sized content**. Empty/unused space is a **bug**, not minimalism — space only earns its place when it serves separation, mis-tap safety, or breathing/readability. A large screen is *more to fill well*, never license to leave content small or stranded. One layout that looks the same on desktop and mobile (proportional, not pixel-guessed). See the user's target sketches: `screenshots/frontend_concept.jpg`, `profiles_concept.jpg`, `upgrades_concept.jpg` (vs the same-named current shots).

## THE WORKFLOW (the breakthrough — use it every time)
This machine has a GPU; Godot can render scenes to PNGs that you can open with the Read tool. **Render → look → fix → render, yourself.** Never guess-and-wait for the user.

Harness files at repo root (throwaway, promote to `tools/` later): `_render.gd` + `_render.tscn`.
Render any screen at exact 1920×1080:
```
"D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://_render.tscn -- res://scenes/<screen>.tscn
```
Output: `res://_render_out.png` — open it with Read to SEE the result. It boots autoloads + selects save slot 0, so screens needing a profile work. For a screen needing different state, edit `_render.gd`.
Save per-screen copies for the user to spot-check: `cp _render_out.png screenshots/<screen>_new.png`.

Parse-check edited scripts (warnings are errors for this user):
```
"D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --headless --check-only --quit --path . scripts/<file>.gd
```

## The proportional-coverage recipe (apply per screen)
- Use `ScreenUI.frame(self, title, exit)` for chrome (the global margin / header ✕ gap / chunky Back are already fixed in `screen_ui.gd`). Root pickers without chrome (like `game_slots.gd`) add their own `ColorRect` bg (`ScreenUI.BG_COLOR`) + a `MarginContainer` outer margin (`int(UIScale.safe_inset()+36)`).
- Fill with containers, **not** pixels: `size_flags_horizontal/vertical = SIZE_EXPAND_FILL` + `size_flags_stretch_ratio` to divide space proportionally. **No `CenterContainer` wrapping a whole menu. No fixed-width content panels.**
- Balance via ratios (all siblings expand and divide), never one element stretched while others are fixed (that made a "monster"), and never all bunched/centered with big margins.
- Gaps: a consistent `add_theme_constant_override("separation", 24)`-ish for breathing — that's the space that earns its place.
- Avoid divergent compact/desktop *sizes* that change the look; the fork may stay only where genuinely needed.

## Done so far
- `screen_ui.gd` (global chrome): outer margin = `safe_inset()+36`; 24px vertical gaps between header/body/footer (fixes ✕ cramped against body); chunky Back (260×96 / 340×130). Header has h-padding + 16 separation.
- `game_world.gd` (Hub): sidebar | actions split by ratio; meta-button row / Continue Run / Abandon divide the height. Matches `frontend_concept`. ✓ rendered-verified.
- `game_slots.gd` (Save Select): dark bg + margin; big title; full-width tall slot rows; big Delete; real Reset button. Matches `profiles_concept`. ✓ rendered-verified (`screenshots/saveselect_new.png`).

## Remaining screens — worst offenders first
(From a full catalogue. Fix each, render, save `<screen>_new.png`.)
1. **Decks** `deck_screen.gd:~76` — right preview panel hardcoded `custom_minimum_size.x = 360/440`. Replace with a stretch-ratio split.
2. **Forge** `combination_screen.gd:~119,124` — right preview fixed 360/420 + `CenterContainer`. Same fix.
3. **Upgrades** `upgrades_screen.gd` + `upgrade_tree_view.gd` — detail strip fixed height; tree cluster small (see `upgrades_concept.jpg`: tree should fill the canvas, bigger tabs/nodes).
4. **Entry / Hello** `entry_screen.gd`, `hello_screen.gd` — `CenterContainer` islands with fixed button/field sizes.
5. **Event** `event_screen.gd:~61` — hardcoded `columns = 6` (overflows compact). Make columns responsive to width.
6. **Deck Select** `deck_select_screen.gd`, **Edit Deck** `deck_build_screen.gd` — fixed card sizes / no fill in places.
7. **Shop** `shop_screen.gd`, **Debug Shop** `debug_shop.gd` — offer slots 150px wide; lots of bottom empty space — let content fill.
8. **Lab** `lab_screen.gd` — "fake full" (busy bg, small actual UI + float gaps); make the interactive content/buttons bigger.
9. **Map** `map.gd`, **Combat HUD** `combat.gd:_build_hud` — HUD button sizing inconsistent; reasonable but review.
10. Mostly-OK (light touch): `reward_screen.gd`, `rest_screen.gd`, `relic_event_screen.gd`, `collection_screen.gd`.

Shared helpers: `ScreenUI` (`screen_ui.gd`) — `frame/scaffold/frame_centered`, `back_button`, `close_button`, `experience_bar`, `BG_COLOR`. `UIScale` (`ui_scale.gd`) — `is_compact()` (true if mobile or window <1100px), `safe_inset()` (40 compact / 28 desktop).

## Calibration lessons (so you don't repeat the painful loop)
- Don't oscillate between "slightly less small" and "stretch one thing to fill the void." The answer is **uniformly big, balanced, proportional**.
- Match the user's concept sketch proportions when one exists; verify by rendering, not by imagining.
- Primary actions are *prominent but proportionate* (bigger, not 4×). Don't let one element swallow the screen; don't bunch a cluster in the middle.

## Housekeeping before committing
- Promote the harness to a real tool, e.g. `tools/render_screen.gd` + `.tscn`, OR delete the scratch files: `_render.gd`, `_render.tscn`, `_render.gd.uid`, `_render.tscn.uid`, `_shot.gd`, `_shot_out.png`, `_render_out.png`. Don't commit the throwaways.
- `screenshots/*_new.png` are review artifacts — keep or drop as the user prefers.
- Commit only when the user asks; branch off main first.
