#!/usr/bin/env python
"""One-shot batch generator for missing ability/relic art via krea2 on ComfyUI.

Builds the full manifest in-line and runs each entry sequentially against
tools/comfy_krea2_gen.py's build_workflow, saving straight to the final
asset path. Safe to re-run: skips any id whose dest file already exists,
unless FORCE_IDS names it explicitly.
"""
import os, sys, time, json

sys.path.insert(0, os.path.dirname(__file__))
from comfy_krea2_gen import build_workflow, post, get, fetch_image, upload_ref

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ABILITY_DIR = os.path.join(ROOT, "assets", "abilities")
RELIC_DIR = os.path.join(ROOT, "assets", "relics")
CHARM_DIR = os.path.join(ROOT, "assets", "charms")
REF_DIR = os.path.join(ROOT, "Tool", "workspace", "art", "ability")

STYLE = ("cartoon art style, 2d illustration, clean bold outlines, "
         "dramatic volumetric light, fantasy game illustration, chibi cartoon style")
ICON_SUFFIX = ("minimal sticker read with thick outline, cell shaded vector graphics, "
               "optimized to read at small size, plain solid white background, icon")

ELEMENT_MATERIAL = {
    "light": "polished golden light-crystal, radiant white-gold glow, holy aura",
    "water": "living sea-glass and flowing water, rippling aqua-blue currents",
    "fire": "molten magma-glass and drifting embers, roaring orange-red flame",
    "darkness": "carved obsidian wreathed in violet-black shadow smoke, umbral energy",
    "earth": "rough granite veined with moss-crystal, earthen brown-green glow",
    "air": "swirling cloud-glass and ribbons of wind, teal-white cyclone glow",
}
ELEMENT_SCENE = {
    "light": "radiant golden holy light descending, glowing white-gold motes",
    "water": "rippling blue water and sea-mist swirling",
    "fire": "roaring orange-red flame and drifting embers",
    "darkness": "swirling violet-black shadow smoke",
    "earth": "rugged brown-green stone dust and mossy light",
    "air": "swirling teal-white wind and cyclone gusts",
}
PIECE_OBJECT = {
    "pawn": "a single chess pawn game piece, small round-headed foot-soldier silhouette",
    "bishop": "a single chess bishop game piece, tall pointed mitre-topped silhouette",
    "knight": "a single chess knight game piece, carved horse-head silhouette",
    "queen": "a single chess queen game piece, crowned tapered silhouette",
}
TRAINING_SCENE = {
    "pawn": "A pawn foot-soldier chess figure drilling in a boot camp, practicing sword strikes, a drill instructor barking orders in the background",
    "bishop": "A bishop cleric chess figure kneeling at a candlelit altar in a sacred rite, receiving blessing energy from above",
    "knight": "A knight chess figure performing daring trick-riding stunts atop a rearing warhorse",
    "queen": "A queen chess figure practicing poised royal etiquette and dance in an ornate ballroom",
}

ELEMENTS = ["light", "water", "fire", "darkness", "earth", "air"]
PIECES = ["pawn", "bishop", "knight", "queen"]

CARD_W, CARD_H = 1024, 1536
ICON_W, ICON_H = 1024, 1024


def ability_entries():
    entries = []

    # --- castling family: img2img off the restored castling.png, matching gale_charge's convention ---
    charge_themes = {
        "warding_charge": "fire elemental theme effects, flame magic, empowering aura",
        "tide_charge": "water elemental theme effects, tide magic, healing aura",
        "radiant_charge": "light elemental theme effects, radiant holy magic, luminous aura",
        "stone_charge": "earth elemental theme effects, stone magic, stalwart aura",
        "umbral_charge": "darkness elemental theme effects, umbral shadow magic, draining aura",
    }
    for aid, theme in charge_themes.items():
        entries.append({
            "id": aid, "dir": "ability", "w": CARD_W, "h": CARD_H,
            "prompt": theme, "rembg": False,
            "ref": os.path.join(REF_DIR, "castling.png"), "denoise": 0.6,
        })

    # --- bless family ---
    for el in ELEMENTS:
        entries.append({
            "id": f"{el}_bless", "dir": "ability", "w": CARD_W, "h": CARD_H, "rembg": False,
            "prompt": (f"A kneeling armored knight chess figure being blessed by descending "
                       f"{ELEMENT_SCENE[el]} from above, blessing hands reaching down, radiant "
                       f"aura enveloping the figure, dramatic divine light shafts, painterly "
                       f"fantasy illustration, vertical composition, {STYLE}"),
        })

    # --- rally ---
    entries.append({
        "id": "rally", "dir": "ability", "w": CARD_W, "h": CARD_H, "rembg": False,
        "prompt": ("A pawn foot-soldier chess figure raising a sword and a tattered rally banner "
                   "high overhead, shouting a battle cry, fellow pawn soldiers cheering behind, "
                   "dramatic warm sunset light, painterly fantasy illustration, vertical composition, "
                   f"{STYLE}"),
    })

    # --- training + training_pure, 6 elements x 4 pieces each ---
    for el in ELEMENTS:
        for pc in PIECES:
            base_scene = TRAINING_SCENE[pc]
            entries.append({
                "id": f"{el}_{pc}_training", "dir": "ability", "w": CARD_W, "h": CARD_H, "rembg": False,
                "prompt": (f"{base_scene}, surrounded by {ELEMENT_SCENE[el]}, painterly fantasy "
                           f"illustration, vertical composition, {STYLE}"),
            })
            entries.append({
                "id": f"{el}_{pc}_training_pure", "dir": "ability", "w": CARD_W, "h": CARD_H, "rembg": False,
                "prompt": (f"{base_scene}, engulfed in an intensely concentrated, twin-plume surge of "
                           f"pure {ELEMENT_SCENE[el]}, brighter and more saturated than normal, radiant "
                           f"refined elemental power, painterly fantasy illustration, vertical composition, "
                           f"{STYLE}"),
            })

    # --- material, 6 elements x 4 pieces ---
    for el in ELEMENTS:
        for pc in PIECES:
            entries.append({
                "id": f"{el}_{pc}_material", "dir": "ability", "w": CARD_W, "h": CARD_H, "rembg": False,
                "prompt": (f"{PIECE_OBJECT[pc]}, carved from and wreathed in {ELEMENT_MATERIAL[el]}, "
                           f"floating and gently rotating, dramatic volumetric light beams, dark vignette "
                           f"background, painterly fantasy illustration, vertical composition, {STYLE}"),
            })

    # --- base (non-elemental) piece materials: pawn/bishop/queen — knight_material already
    # exists and set this convention (single black chess piece on a table, cel-shaded, flat
    # charcoal-grey body with slate-blue highlights, minimal composition, no elemental theming) ---
    base_material_piece = {
        "pawn": "chess pawn",
        "bishop": "chess bishop",
        "queen": "chess queen",
    }
    for pc, label in base_material_piece.items():
        entries.append({
            "id": f"{pc}_material", "dir": "ability", "w": CARD_W, "h": CARD_H, "rembg": False,
            "prompt": (f"Single black {label} on a table, centered upright on a chess board, bold "
                       f"dark outlines, flat cel-shaded cartoon vector style, charcoal-grey body with "
                       f"soft slate-blue highlights, glossy sheen accents, clean minimal composition, "
                       f"gentle even lighting, {STYLE}"),
        })

    return entries


def charm_entries():
    defs = {
        "sharpened": "A honing whetstone charm with a razor-sharp blade edge etched into it, glinting steel-silver light",
        "sturdy": "A small riveted iron buckle charm, thick and unyielding, dull steel sheen",
        "swift": "A winged sandal-strap charm trailing a wisp of speed lines, light silvery-blue motion blur",
        "warded": "A small engraved ward-stone charm etched with a protective rune, soft cyan glow",
        "vampiric": "A fanged crimson gem charm dripping a single bead of blood-red light, dark ruby glow",
        "thorned": "A twisted bramble-vine charm coiled into a ring, sharp black thorns catching the light",
        "rallying": "A tiny banner-and-drum charm, a miniature war drum with a small flag planted atop it, warm bronze glow",
    }
    entries = []
    for cid, desc in defs.items():
        entries.append({
            "id": cid, "dir": "charm", "w": ICON_W // 2, "h": ICON_H // 2, "rembg": True,
            "prompt": f"{desc}, {STYLE}, {ICON_SUFFIX}",
        })
    return entries


def relic_entries():
    defs = {
        "septic_ward": "A small clay ward totem oozing sickly green poison mist, wrapped protectively around a glowing shield glyph",
        "zephyr_charm": "A feather charm caught mid-swirl in a gust of wind, wrapped in a faint shimmering barrier bubble",
        "gale_sigil": "A rune-carved stone sigil etched with a spiraling wind glyph, swirling air currents rising off it",
        "cyclone_totem": "A small wooden totem carved with a spiraling cyclone motif, a miniature wind funnel swirling above it",
        "trueshot_sigil": "A stone sigil emblazoned with a crosshair-pierced eye motif, an arrow frozen mid-flight, ominous red glow",
        "berserkers_momentum": "A berserker's clenched gauntlet wreathed in roaring fire, knuckles glowing like embers",
        "eagle_eye_charm": "An eagle feather charm set with a glowing golden eye motif, sharp focused golden light",
        "warlords_fury": "A warlord's battle emblem of crossed flaming axes, fierce orange-red glow",
        "steady_hand_ward": "A smooth stone ward etched with a steady open palm rune, calm cool grey-blue glow",
        "executioners_edge": "A dark executioner's axe blade wreathed in violet-black shadow energy, edge glowing with lethal power",
    }
    entries = []
    for rid, desc in defs.items():
        entries.append({
            "id": rid, "dir": "relic", "w": ICON_W, "h": ICON_H, "rembg": True,
            "prompt": f"{desc}, {STYLE}, {ICON_SUFFIX}",
        })
    return entries


def dest_path(entry):
    d = {"ability": ABILITY_DIR, "relic": RELIC_DIR, "charm": CHARM_DIR}[entry["dir"]]
    return os.path.join(d, f"{entry['id']}.png")


def run_entry(entry, port):
    dest = dest_path(entry)
    ref_filename = None
    denoise = 1.0
    if entry.get("ref"):
        ref_filename = upload_ref(entry["ref"])
        denoise = entry.get("denoise", 0.6)

    seed = int.from_bytes(os.urandom(4), "big")
    wf = build_workflow(entry["prompt"], entry["w"], entry["h"], steps=8, cfg=1.0,
                         seed=seed, prefix="cardgame", rembg=entry.get("rembg", False),
                         rembg_model="Inspyrenet", ref_filename=ref_filename, denoise=denoise)

    pid = post("/prompt", {"prompt": wf})["prompt_id"]
    t0 = time.time()
    while True:
        hist = get(f"/history/{pid}")
        if pid in hist:
            break
        if time.time() - t0 > 300:
            raise TimeoutError(f"{entry['id']} timed out")
        time.sleep(1.5)

    h = hist[pid]
    for node in h.get("outputs", {}).values():
        for img in node.get("images", []):
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(fetch_image(img))
            return dest
    raise RuntimeError(f"{entry['id']}: no image output, status={h.get('status')}")


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--only", nargs="*", default=None, help="only generate these ids")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="regenerate even if dest exists")
    a = ap.parse_args()

    import comfy_krea2_gen as m
    m.SERVER = f"http://127.0.0.1:{a.port}"

    entries = ability_entries() + relic_entries() + charm_entries()
    if a.only:
        wanted = set(a.only)
        entries = [e for e in entries if e["id"] in wanted]

    print(f"[manifest] {len(entries)} entries")
    done, skipped, failed = 0, 0, 0
    for i, entry in enumerate(entries, 1):
        dest = dest_path(entry)
        if os.path.exists(dest) and not a.force:
            print(f"[{i}/{len(entries)}] SKIP {entry['id']} (exists)")
            skipped += 1
            continue
        if a.dry_run:
            print(f"[{i}/{len(entries)}] WOULD GEN {entry['id']} -> {dest}")
            continue
        t0 = time.time()
        try:
            out = run_entry(entry, a.port)
            print(f"[{i}/{len(entries)}] OK {entry['id']} -> {out} ({time.time()-t0:.1f}s)")
            done += 1
        except Exception as ex:
            print(f"[{i}/{len(entries)}] FAIL {entry['id']}: {ex}")
            failed += 1

    print(f"[summary] done={done} skipped={skipped} failed={failed} total={len(entries)}")


if __name__ == "__main__":
    main()
