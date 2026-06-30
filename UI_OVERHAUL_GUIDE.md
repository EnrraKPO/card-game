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
- `deck_screen.gd` (Decks): preview pane fixed-width → stretch-ratio split (deck grid 1.7 : preview 1.0); actions now a 2-col grid of chunky full-width buttons via `_make_action_button`. ✓ `decks_new.png`.
- `combination_screen.gd` (Forge): right preview fixed-width + `CenterContainer` island → filled `PanelContainer` split by ratio (left 2.2 : right 1.0), "Preview" header + bigger preview card. ✓ `forge_new.png`.
- `upgrade_tree_view.gd` (Upgrades tree): now scales-to-fit AND centers — small trees blow up (cap `MAX_SCALE`), big trees shrink (floor `MIN_SCALE`), never scroll; node/font/link sizes all scale. `upgrades_screen.gd`: chunky desktop Buy button + taller detail strip. Matches `upgrades_concept`. ✓ `upgrades_new.png`.
- `hello_screen.gd` / `entry_screen.gd`: added dark `ScreenUI.BG_COLOR` bg (was raw engine gray); big title + chunky Play/Continue + properly-placed/sized Reset. ✓ `hello_new.png`.
- `event_screen.gd` (Event): hardcoded 6-col scroll grid → `FitGrid` that fills + sizes cards; bigger title/blurb/gold/status + chunky upgrade button. ✓ `event_new.png`.
- `shop_screen.gd` (Shop): buy/remove split by ratio (was fixed-420 remove panel); chunky full-width Buy buttons + gold-colored prices + bigger fonts; remove deck via `FitGrid`. ✓ `shop_new.png`.
- `deck_select_screen.gd` (Deck Select): stranded top-left 4-col grid → `FitGrid` of card-shaped tiles (King card + bottom name/count banner), matches Decks screen, fills canvas. ✓ `deckselect_new.png`.
- `deck_build_screen.gd` (Edit Deck): bigger tiles (`_tile_w` 112 desktop), chunky desktop Save button, bigger status. ✓ `deckbuild_new.png`.

### Harness note
`_render.gd` now starts a run (with sample charms) for run-dependent scenes and sets `editing_deck_id`/`viewing_deck_id`, so Forge/Shop/Event/Deck-Build render with real content.

- `lab_screen.gd` (Lab): reworked over several rounds of feedback. Final = a **"room" with two full-area states** over the **darkened** room art. Working area shows either the three artifacts as BIG clickable objects (`_make_artifact_object`), or — once clicked — that artifact's crafting workspace filling the area with a "‹ Lab" back button (`_build_craft_panel`/`_close_artifact`); no dim modal. Forge bodies split the card preview into its OWN column (`_assemble_forge`) so it doesn't fight the action button. **Working area + resources sit SIDE BY SIDE on desktop** (HBox: work 2.6 | resources column 1.0) so they can't overlap on short windows; **stacked** on compact. (Earlier stacked-everywhere version overflowed the crafting panel down over the resources at 1366×768 — that's why it's side-by-side now.) ✓ `lab_room_new.png`, `lab_craft_new.png`.

## Remaining screens
1. **Debug Shop** `debug_shop.gd` — dev tool; low priority.
2. **Map** `map.gd`, **Combat HUD** `combat.gd:_build_hud` — HUD button sizing inconsistent; reasonable but review.
3. Mostly-OK (light touch): `reward_screen.gd`, `rest_screen.gd`, `relic_event_screen.gd`, `collection_screen.gd`.

Shared helpers: `ScreenUI` (`screen_ui.gd`) — `frame/scaffold/frame_centered`, `back_button`, `close_button`, `experience_bar`, `BG_COLOR`. `UIScale` (`ui_scale.gd`) — `is_compact()` (true if mobile or window <1100px), `safe_inset()` (40 compact / 28 desktop).

## Calibration lessons (so you don't repeat the painful loop)
- Don't oscillate between "slightly less small" and "stretch one thing to fill the void." The answer is **uniformly big, balanced, proportional**.
- Match the user's concept sketch proportions when one exists; verify by rendering, not by imagining.
- Primary actions are *prominent but proportionate* (bigger, not 4×). Don't let one element swallow the screen; don't bunch a cluster in the middle.

## Housekeeping before committing
- Promote the harness to a real tool, e.g. `tools/render_screen.gd` + `.tscn`, OR delete the scratch files: `_render.gd`, `_render.tscn`, `_render.gd.uid`, `_render.tscn.uid`, `_shot.gd`, `_shot_out.png`, `_render_out.png`. Don't commit the throwaways.
- `screenshots/*_new.png` are review artifacts — keep or drop as the user prefers.
- Commit only when the user asks; branch off main first.
