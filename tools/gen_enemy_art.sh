#!/usr/bin/env bash
# Generate Flux 2 dev card art for the enemy-tribe cards, straight into
# assets/cards/<id>.png. Cartoon / 2d-illustration style (the proven look for
# this project's generated assets — see memory comfyui_assets).
#
#   bash tools/gen_enemy_art.sh [PORT] [card_id ...]
#
# PORT defaults to 8188 (the healthy Desktop instance; 8187 is often a stale
# instance). With no card ids it generates ALL of them; pass ids to redo a subset:
#   bash tools/gen_enemy_art.sh 8188 ghoul vampire_lord
set -u
PORT="${1:-8188}"; shift || true
WANT=("$@")   # optional subset of card ids
cd "$(dirname "$0")/.."

STYLE="Bold clean linework, vibrant colors, dramatic lighting, simple atmospheric background, trading card game character art."
PRE="2d illustration, cartoon art style. A full-body fantasy character portrait of"

declare -A P
P[goblin_cutter]="a small scrappy goblin warrior with bright green skin, big pointy ears, wearing a tattered loincloth and gripping a rusty jagged dagger, snarling with a mischievous grin in a crouched ready-to-pounce pose."
P[goblin_fanatic]="a frenzied goblin berserker with green skin, wild bloodshot eyes and a foaming mouth, covered in crude red war paint, swinging a crude axe overhead while screaming in a manic dynamic pose."
P[goblin_bomber]="a sneaky goblin bomber with green skin and a manic grin, cradling a round black bomb with a lit sparking fuse, a satchel of bombs slung over one shoulder, soot stains on its face."
P[goblin_warboss]="a hulking goblin warboss with dark green skin, crude spiked iron armor decorated with bone trophies, wielding a massive cleaver, standing in a commanding battle-ready pose with battle scars."
P[skeleton_grunt]="an undead skeleton warrior in rusted dented armor, holding a broken notched sword, eye sockets glowing faint blue, a tattered cape, standing menacingly."
P[bone_archer]="an undead skeleton archer drawing a bow made of bone, a cursed arrow glowing sickly green, an exposed ribcage, a tattered hood and cloak."
P[ghoul]="a feral ghoul, an emaciated undead monster with pale grey rotting skin, long sharp claws and a wide jagged-toothed mouth, hunched and drooling in a lunging pose."
P[vampire_lord]="an aristocratic vampire lord with pale skin, glowing red eyes and sharp fangs, wearing an ornate black and crimson high-collared cape and gothic noble attire, in an elegant menacing pose with one clawed hand raised."
P[stone_sentinel]="an ancient humanoid stone golem guardian made of mossy weathered grey rock, glowing carved blue runes across its body, heavy and massive, standing guard."
P[iron_bulwark]="a massive iron golem construct of riveted metal plates, carrying a huge tower shield, a glowing orange energy core in its chest, planted in a sturdy defensive stance."
P[granite_smasher]="an enraged granite golem with a cracked grey rock body glowing with molten orange cracks, enormous heavy stone fists raised to smash, bits of rubble flying around it."
P[colossus]="a colossal towering stone titan, an enormous mountain golem built of carved ancient rock covered in moss and glowing blue runes, seen from a low dramatic angle to emphasize its epic scale."

ORDER=(goblin_cutter goblin_fanatic goblin_bomber goblin_warboss \
       skeleton_grunt bone_archer ghoul vampire_lord \
       stone_sentinel iron_bulwark granite_smasher colossus)

want() { [ ${#WANT[@]} -eq 0 ] && return 0; for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1; }

for id in "${ORDER[@]}"; do
  want "$id" || continue
  echo "=== $id ==="
  python tools/comfy_gen.py "$PRE ${P[$id]} $STYLE" \
    --dest "assets/cards/$id.png" --out "enemy_$id" \
    --w 1024 --h 1536 --port "$PORT" 2>&1 | grep -E "saved|error|timeout|done"
done
echo "=== enemy art batch complete ==="
