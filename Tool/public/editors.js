/* editors.js — per-content-type editor definitions.
 * Each editor provides:
 *   newItem()                    — a fresh draft
 *   form(draft, ctx, onChange)   — the editing DOM
 *   serialize(draft)             — the workspace/deploy JSON (tool-only keys prefixed "_")
 *   summarize(draft)             — plain-English lines for the summary panel
 *   promptFor(draft)             — default ComfyUI prompt
 *   artNote                      — what the art is used for (or that the game ignores it)
 */
'use strict';

function fxCtx(ctx, ownerNoun) {
  return {
    vocab: ctx.vocab,
    ownerNoun,
    type: ctx.type,   // the item type — /api/effects/from-text biases its examples by it
    statusIds: () => {
      const game = ctx.vocab.statuses.map(s => s.id);
      const ws = (ctx.workspace.status || []).map(s => s.id);
      return [...new Set([...game, ...ws])];
    },
  };
}

function abilityIds(ctx) {
  const game = ctx.vocab.abilities.map(a => a.id);
  const ws = (ctx.workspace.ability || []).map(a => a.id);
  return [...new Set([...game, ...ws])];
}

// Tribe entities (data/tribes) — options for the card editor's tribe select and the
// encounter editor's tribes label. Read from the live game state (app.js global).
function tribeOptions() {
  const list = (typeof state !== 'undefined' && state.game && state.game.tribe) ? state.game.tribe : [];
  return list.slice().sort((a, b) => a.id.localeCompare(b.id))
    .map(t => ({ value: t.id, label: `${t.name} (${t.id})` }));
}

function cardIdOptions(ctx, filter) {
  const f = filter || (() => true);
  const game = ctx.vocab.cards.filter(f)
    .map(c => ({ value: c.id, label: `${c.name} (${c.id})` }));
  // workspace drafts pass through the same filter, built from their data
  const ws = (ctx.workspace.card || []).filter(c => {
    const d = c.data || {};
    return f({
      id: c.id, is_king: !!d.is_king, enemy_only: !!d.enemy_only,
      card_type: d.card_type || ((d.elements || []).length && !(d.chess_pieces || []).length ? 'spell' : 'unit'),
    });
  }).map(c => ({ value: c.id, label: `${(c.data && c.data.display_name) || c.id} (${c.id}) [tool]` }));
  return game.concat(ws);
}

function idField(draft, onChange, isNew) {
  const input = textInput(draft, 'id', onChange, 'lowercase_with_underscores');
  if (!isNew) input.disabled = true;
  return fld('ID', input, isNew ? 'unique; lowercase letters, digits, underscores — fixed after creation' : 'fixed after creation');
}

function cleanEffects(list) { return (list || []).map(cleanEffectForDeploy); }

// ── enemy-engine vocabulary (mirrors scripts/card_data.gd :: role and
//    scripts/enemy/board_scoring.gd :: STOCK_SURVIVAL_WEIGHTS) ────────────────
// A unit's ROLE is one tag, never load-bearing: an untagged unit resolves through the
// weight table's "default" entry and still fights correctly. The encounter's
// survival_weights layer over the stock table below — keep these values in sync with
// the GDScript constant, they are shown as the blank-field placeholders.
const UNIT_ROLES = [
  { value: 'fodder',  label: 'Fodder — cheap, expendable body' },
  { value: 'tank',    label: 'Tank — meant to stand in front and absorb' },
  { value: 'dps',     label: 'DPS — the damage the fight is built around' },
  { value: 'support', label: 'Support — heals/buffs, worth shielding' },
  { value: 'burst',   label: 'Burst — high-value nuker, worth shielding' },
];
const STOCK_SURVIVAL_WEIGHTS = {
  captain: 1.75, support: 0.5, burst: 0.4, dps: 0.3, tank: 0.15, fodder: 0.05, default: 0.1,
};

// ═════════════════════════════════ CARD ═════════════════════════════════════
const CardEditor = {
  label: 'Card',
  newItem: () => ({
    id: '', display_name: '', description: '', art_instructions: '',
    cost: 1, attack: 2, health: 3, speed: 3, shield: 0,
    elements: [], chess_pieces: [], effects: [], abilities: [],
    ranged: false, is_king: false, enemy_only: false, target_policy: '', role: '',
    // bounty_gold / bounty_exp are deliberately ABSENT by default: an unset bounty derives
    // from the card's mana cost through the bounty.* rates (see GameData.kill_bounty), and a
    // key that is only written when authored keeps every existing card file untouched.
    _derive_stats: false,
  }),
  form(draft, ctx, onChange) {
    const wrap = el('div');
    for (const k of ['elements', 'chess_pieces', 'effects', 'abilities']) if (!draft[k]) draft[k] = [];

    const statRow = el('div', { class: 'frow' },
      fld('Mana cost', numInput(draft, 'cost', onChange, { min: 0 }), null, 'narrow'),
      fld('Attack', numInput(draft, 'attack', onChange), null, 'narrow'),
      fld('Health', numInput(draft, 'health', onChange, { min: 1 }), null, 'narrow'),
      fld('Speed', numInput(draft, 'speed', onChange), 'higher acts first', 'narrow'),
      fld('Shield', numInput(draft, 'shield', onChange, { min: 0 }), 'refreshes each round', 'narrow'),
    );
    const syncStats = () => {
      statRow.querySelectorAll('input').forEach(i => { i.disabled = !!draft._derive_stats; });
    };

    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Prompt instructions' }),
            el('textarea', { value: draft.art_instructions || '',
              placeholder: 'optional — steers ✨ art-prompt generation for this card (never shown in game; the flavour text no longer influences art)',
              oninput: e => { draft.art_instructions = e.target.value; onChange(); } })),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld' }, checkInput(draft, 'ranged', onChange, 'Ranged — fires a projectile instead of lunging')),
          el('div', { class: 'fld' }, checkInput(draft, 'is_king', onChange, 'King unit (win/lose condition)')),
          el('div', { class: 'fld' }, checkInput(draft, 'enemy_only', onChange, 'Enemy-only (CPU fodder, never offered to the player). Tick this + King for an enemy CAPTAIN. Enemy art deploys to assets/cards/enemies/.')),
          fld('Tribe', tribeOptions().length
            ? selectInput(draft, 'tribe', tribeOptions(), onChange, { optional: true, emptyLabel: '(none)' })
            : textInput(draft, 'tribe', onChange, 'tribe id'),
            'groups enemy units in ⚔ Encounters; the tribe\'s canonical style joins art generation', 'narrow'),
        ),
        el('div', { class: 'frow' },
          fld('Plays as', selectInput(draft, 'card_type', [
            { value: 'unit', label: 'Unit (fielded on the board)' },
            { value: 'spell', label: 'Spell (cast, never fielded)' },
          ], onChange, { optional: true, emptyLabel: 'auto — elements-only = spell, otherwise unit' })),
          fld('Auto-attack target', selectInput(draft, 'target_policy', [
            { value: 'nearest', label: 'Nearest — the closest enemy' },
            { value: 'leaper', label: 'Leaper — jumps the front column to the backline' },
            { value: 'wounded', label: 'Wounded — the enemy with the lowest health' },
            { value: 'tank', label: 'Tank — the enemy with the highest health' },
            { value: 'threat', label: 'Threat — the enemy with the highest attack' },
          ], onChange, { optional: true, emptyLabel: 'auto — from chess composition' }),
            'how this unit picks whom to auto-attack; a matching line is appended to the card text (spells never auto-attack)'),
          fld('Battlefield role', selectInput(draft, 'role', UNIT_ROLES, onChange,
            { optional: true, emptyLabel: 'untagged — uses the "default" weight' }),
            'what the ENEMY ENGINE thinks this unit is worth protecting; an encounter can re-price any role. Kings need no role — they are always the Captain'),
        ),
      ),
      groupBox('Text (shown on the card)', locFields(draft, { type: 'card', typeLabel: 'card', onChange,
        describeLines: () => (draft.effects || []).map(e => describeEffect(e, 'this card')) })),
      groupBox('Composition',
        el('div', { class: 'frow' },
          el('div', { class: 'fld' }, el('span', { class: 'lab', text: 'Elements' }),
            chipSet(draft.elements, ctx.vocab.elements, onChange, id => labelOf('element', id))),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld' }, el('span', { class: 'lab', text: 'Chess pieces' }),
            chipSet(draft.chess_pieces, ctx.vocab.pieces, onChange, id => labelOf('piece', id))),
        ),
        el('div', { class: 'hint', text: 'A card with only elements and no pieces plays as a SPELL. A rook in the composition makes it a rooted building. Use the canonical id: elements+pieces sorted alphabetically (e.g. darkness_water_pawn).' }),
      ),
      groupBox('Stats',
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, checkInput(draft, '_derive_stats', () => { syncStats(); onChange(); },
            'Derive stats from the composition (composition cards only — the game computes cost/attack/health/speed, you just attach effects)')),
        ),
        statRow,
        el('div', { class: 'frow' },
          fld('Bounty gold', numInput(draft, 'bounty_gold', onChange, { min: 0, optional: true }),
            'gold paid when this unit is killed — blank = its mana cost', 'narrow'),
          fld('Bounty exp', numInput(draft, 'bounty_exp', onChange, { min: 0, optional: true }),
            'experience paid when it is killed — blank = its mana cost', 'narrow'),
        ),
        el('div', { class: 'hint', text: 'Bounties pay the player mid-fight, the instant the unit dies — one coin flies to the gold bag per gold. Leave both blank unless this unit should be worth more (or less) than it costs. Kings pay no bounty; they drop the reward chest instead.' }),
      ),
      groupBox('Activated abilities',
        el('div', { class: 'fld' },
          el('span', { class: 'lab', text: 'Abilities this card offers (definitions live in the Abilities tab)' }),
          chipSet(draft.abilities, abilityIds(ctx), onChange)),
      ),
      groupBox('Effects'),
    );
    renderEffectList(wrap.lastChild, draft.effects, fxCtx(ctx, 'this card'), onChange);
    syncStats();
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id };
    if (!d._derive_stats) {
      out.display_name = d.display_name;
      out.cost = d.cost; out.attack = d.attack; out.health = d.health; out.speed = d.speed;
      if (d.shield) out.shield = d.shield;
    } else {
      out._derive_stats = true;
      if (d.display_name) out.display_name = d.display_name;
    }
    if (d.description) out.description = d.description;
    if (d.art_instructions) out.art_instructions = d.art_instructions;   // authoring-only; steers art-prompt generation
    if (d.elements.length) out.elements = d.elements.slice().sort();
    if (d.chess_pieces.length) out.chess_pieces = d.chess_pieces.slice().sort();
    if (d.is_king) out.is_king = true;
    if (d.enemy_only) out.enemy_only = true;
    if (d.tribe) out.tribe = d.tribe;   // fodder-tribe tag (cue variants); no form input yet
    if (d.ranged) out.ranged = true;
    if (d.target_policy) out.target_policy = d.target_policy;   // "" = auto (derive from composition)
    if (d.role) out.role = d.role;   // "" = untagged (falls to the survival table's "default")
    // 0 is a real bounty ("pays nothing"), so these test for PRESENCE, not truthiness.
    if (d.bounty_gold != null && d.bounty_gold !== '') out.bounty_gold = d.bounty_gold;
    if (d.bounty_exp != null && d.bounty_exp !== '') out.bounty_exp = d.bounty_exp;
    if (d.card_type) out.card_type = d.card_type;
    if (d.shield && d._derive_stats) out.shield = d.shield;
    if (d.effects.length) out.effects = cleanEffects(d.effects);
    if (d.abilities.length) out.abilities = d.abilities.slice();
    return out;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    for (const k of ['elements', 'chess_pieces', 'effects', 'abilities']) if (!d[k]) d[k] = [];
    const comp = d.elements.length + d.chess_pieces.length;
    d._derive_stats = comp > 0 && d.attack == null;
    for (const k of ['cost', 'attack', 'health', 'speed', 'shield']) if (d[k] == null) d[k] = k === 'health' ? 1 : 0;
    return d;
  },
  summarize(d) {
    const lines = [];
    const kind = d.elements.length && !d.chess_pieces.length ? 'Spell' : (d.chess_pieces.includes('rook') ? 'Building' : 'Unit');
    const comp = [...d.elements, ...d.chess_pieces].join(' + ');
    // name/kind and composition are SEPARATE lines: the LLM-visibility checklist toggles
    // per line, and a name is often unrelated to the materials that compose the card
    lines.push(`${d.display_name || d.id || 'Unnamed'} — ${kind}.`);
    if (comp) lines.push(`Composition: ${comp}.`);
    if (d._derive_stats) lines.push('Stats derived from the composition by the game.');
    else lines.push(`Cost ${d.cost} · ATK ${d.attack} · HP ${d.health} · SPD ${d.speed}${d.shield ? ' · Shield ' + d.shield : ''}.`);
    if (d.ranged) lines.push('Attacks at range (projectile).');
    if (d.target_policy) lines.push(`Auto-attack targets: ${d.target_policy}.`);
    if (d.bounty_gold != null && d.bounty_gold !== '') lines.push(`Pays ${d.bounty_gold} gold when killed.`);
    if (d.bounty_exp != null && d.bounty_exp !== '') lines.push(`Pays ${d.bounty_exp} experience when killed.`);
    if (d.is_king) lines.push('KING — losing it loses the fight.');
    if (d.enemy_only) lines.push('Enemy-only: never appears in player pools.');
    for (const a of d.abilities || []) lines.push(`Offers activated ability: ${a}.`);
    for (const e of d.effects || []) lines.push(describeEffect(e, 'this card'));
    return lines;
  },
  // Deliberately never says "card"/"tcg" (the model renders a whole framed card with
  // stats) and never includes description/effect text (it gets rendered AS text).
  promptFor(d) {
    const pieces = d.chess_pieces || [], els = d.elements || [];
    const kind = els.length && !pieces.length ? 'spell' : pieces.includes('rook') ? 'building' : 'creature';
    // NEVER name the elements or pieces: the theme is carried by reference art, not by
    // prompt words, and the id encodes the composition. Subject stays generic; identity
    // rides the display name only (which the author controls).
    const subject =
      kind === 'spell' ? 'a dramatic burst of arcane magic' :
      kind === 'building' ? 'an imposing fantasy fortification' :
      d.is_king ? 'a regal fantasy ruler in ornate armor' : 'a fantasy combatant';
    const name = d.display_name || '';
    // no background guidance on purpose — a fixed phrase here ("ornate dark background")
    // homogenized every generation, and the ✨ LLM parroted it from the example
    return `Rich glowing painterly fantasy illustration of ${name ? name + ', ' : ''}${subject}, dramatic volumetric lighting, high detail`;
  },
  artNote: 'Installed to assets/cards/<id>.png — shown on the card in game.',
};

// ═════════════════════════════════ RELIC ════════════════════════════════════
const RelicEditor = {
  label: 'Relic',
  newItem: () => ({ id: '', display_name: '', description: '', color: 'ccbc72', letter: '✦', price: 90, effects: [] }),
  form(draft, ctx, onChange) {
    if (!draft.effects) draft.effects = [];
    const wrap = el('div');
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Chip colour', colorInput(draft, 'color', onChange), 'fallback chip when there is no icon', 'narrow'),
          fld('Chip glyph', textInput(draft, 'letter', onChange, '✦'), 'one letter/symbol', 'narrow'),
          fld('Shop price (gold)', numInput(draft, 'price', onChange, { min: 0 }), null, 'narrow'),
        ),
      ),
      groupBox('Text (shown in shop / relic tray)', locFields(draft, { type: 'relic', typeLabel: 'relic', onChange,
        describeLines: () => (draft.effects || []).map(e => describeEffect(e, 'this relic')) })),
      groupBox('Run-wide effects'),
    );
    renderEffectList(wrap.lastChild, draft.effects, fxCtx(ctx, 'this relic'), onChange);
    return wrap;
  },
  serialize(d) {
    return { id: d.id, display_name: d.display_name, description: d.description || '',
      color: d.color || 'ccbc72', letter: d.letter || '✦', price: d.price == null ? 80 : d.price,
      effects: cleanEffects(d.effects) };
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed relic'} — ${d.price || 0} gold in shops.`];
    for (const e of d.effects || []) lines.push(describeEffect(e, 'this relic'));
    lines.push('Effects are run-wide and fire from your side only.');
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.effects) d.effects = [];
    return d;
  },
  promptFor(d) {
    return `Single centered fantasy relic item, ${d.display_name || slugToName(d.id)}, ${d.description || ''}, rich glowing painterly style, ornate magical artifact, on a plain solid white background`;
  },
  artNote: 'Installed to assets/relics/<id>.png — replaces the letter chip in game. Background removal recommended.',
};

// The SPREAD block (mirrors StatusData.spread / the cascade's spread tier): once per stack
// at its phase the status rolls — a chance to propagate one stack to a destination, else a
// chance for that stack to die down. The wildfire vocabulary: burning creeps to adjacent
// slots; a unit's ablaze lights the ground beneath it (arriving AS burning).
function renderSpreadBox(draft, ctx, onChange) {
  const box = groupBox('Spread — each stack may propagate or die down (per-stack roll)');
  const fx = fxCtx(ctx, 'the carrier');
  const render = () => {
    box.replaceChildren(box.firstChild);
    if (!draft.spread) {
      box.append(el('button', { class: 'ghost small list-add', text: '+ this status spreads (wildfire-style)', onclick: () => {
        draft.spread = { phase: 'turn_start', chance: 0.2, decay_chance: 0.4 };
        onChange(); render();
      } }));
      return;
    }
    const s = draft.spread;
    box.append(el('div', { class: 'frow' },
      fld('Rolls at', selectInput(s, 'phase', [
        { value: 'turn_start', label: 'start of round' },
        { value: 'turn_end', label: 'end of round' },
      ], onChange)),
      fld('Propagate chance', numInput(s, 'chance', onChange, { float: true, step: 0.05, min: 0, max: 1 }),
        'per stack, 0–1', 'narrow'),
      fld('Else die down', numInput(s, 'decay_chance', onChange, { float: true, step: 0.05, min: 0, max: 1 }),
        'rolled only when the leap failed; with no phase decay, this is the status’s whole lifetime', 'narrow'),
      el('div', { class: 'fld narrow', style: 'justify-content:flex-end' },
        el('button', { class: 'ghost tiny', text: '✕ no spread', onclick: () => { delete draft.spread; onChange(); render(); } })),
    ));
    box.append(el('div', { class: 'frow' },
      fld('Destination', selectInput(s, 'to', [
        { value: 'adjacent', label: 'a random adjacent slot, same half (ground fire creeping)' },
        { value: 'ground', label: 'the slot the carrier stands on (a unit lighting its floor)' },
      ], onChange, { optional: true, emptyLabel: 'a random adjacent slot (default)' })),
      fld('Arrives as', selectInput(s, 'status', fx.statusIds(), onChange, { optional: true, emptyLabel: '(itself)' }),
        'what the destination catches; a cross-layer leap must speak the destination layer (ablaze arrives as burning)'),
      fld('Arrival touch', selectInput(s, 'arrival', (ctx.vocab.namedEffects || []).map(n => ({ value: n.id, label: n.name || n.id })),
        onChange, { optional: true, emptyLabel: '(none)' }),
        'named effect dealt to whoever STANDS on the caught slot (burning: "burn" — damage and ignition in one)'),
    ));
  };
  render();
  return box;
}

// ═════════════════════════════════ STATUS ═══════════════════════════════════
const StatusEditor = {
  label: 'Status',
  newItem: () => ({ id: '', display_name: '', description: '', beneficial: false, aura: false,
    color: '8fd0ff', glyph: '✦', default_duration: 2, decay: 'duration', decay_phase: 'turn_end',
    stacking: 'refresh', max_stacks: 9, effects: [], abilities: [] }),
  form(draft, ctx, onChange) {
    for (const k of ['effects', 'abilities']) if (!draft[k]) draft[k] = [];
    if (!draft.eval) draft.eval = {};
    const wrap = el('div');
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          el('div', { class: 'fld' }, checkInput(draft, 'beneficial', onChange, 'Beneficial (buff tint; unchecked = debuff)')),
          el('div', { class: 'fld' }, checkInput(draft, 'aura', onChange, 'Aura frame — draw a persistent frame over the card')),
          fld('Pip colour', colorInput(draft, 'color', onChange), null, 'narrow'),
          fld('Pip glyph', textInput(draft, 'glyph', onChange, '☠'), 'short symbol', 'narrow'),
        ),
      ),
      groupBox('Text (tooltip)', locFields(draft, { type: 'status', typeLabel: 'status', onChange,
        describeLines: () => (draft.effects || []).map(e => describeEffect(e, 'the carrier')) })),
      groupBox('Lifecycle',
        el('div', { class: 'frow' },
          fld('Wears off by', selectInput(draft, 'decay', ['duration','stacks','none','intercept'].map(v => ({ value: v, label: labelOf('decay', v) })), onChange)),
          fld('Counts down at', selectInput(draft, 'decay_phase', [
            { value: 'turn_end', label: 'end of round (default)' },
            { value: 'turn_start', label: 'start of round' },
            { value: 'attack', label: 'per attack (for stack-per-attack statuses)' },
          ], onChange)),
        ),
        el('div', { class: 'frow' },
          fld('Re-applying', selectInput(draft, 'stacking', ['refresh','extend','stack','independent'].map(v => ({ value: v, label: labelOf('stacking', v) })), onChange)),
          fld('Default duration', numInput(draft, 'default_duration', onChange, { min: 1 }), 'rounds, when the applier doesn’t override', 'narrow'),
          fld('Max stacks', numInput(draft, 'max_stacks', onChange, { min: 1 }), null, 'narrow'),
        ),
      ),
      groupBox('Granted abilities (while active)',
        el('div', { class: 'fld' },
          el('span', { class: 'lab', text: 'Activated abilities the carrier gains while this status rides it' }),
          chipSet(draft.abilities, abilityIds(ctx), onChange)),
      ),
      // The enemy engine's per-STACK pricing (STATUS_EVAL_BRIEF.md): folded × stacks at
      // capture. The flat, stack-blind half (and all muls) is authored on the EFFECTS
      // below — this level exists because only the status knows what a stack is.
      groupBox('Enemy eval pricing (per stack)',
        el('div', { class: 'hint', text: 'How each STACK moves the enemy engine’s reading of the '
          + 'carrier, folded × stacks (burning: exposure +0.25/stack; barrier: exposure −2/stack). '
          + 'Adds only — a flat annotation or a multiplier goes on the effect that carries the '
          + 'behaviour. Empty = stacks are priced by the effects alone. Never price a standing '
          + 'stat effect’s stats here: captured stats already say it (double count).' }),
        el('div', { class: 'frow' },
          fld('Threat / stack', numInput(draft.eval, 'threat', onChange, { float: true, step: 'any', optional: true, placeholder: '—' }),
            'damage/round the carrier’s output gains per stack', 'narrow'),
          fld('Exposure / stack', numInput(draft.eval, 'exposure', onChange, { float: true, step: 'any', optional: true, placeholder: '—' }),
            'damage/round onto the carrier per stack; a soak is negative', 'narrow'),
          fld('Value / stack', numInput(draft.eval, 'value', onChange, { float: true, step: 'any', optional: true, placeholder: '—' }),
            'value-units per stack for what is neither', 'narrow'),
        ),
      ),
      renderSpreadBox(draft, ctx, onChange),
      groupBox('Effects it carries'),
    );
    renderEffectList(wrap.lastChild, draft.effects, fxCtx(ctx, 'the carrier'), onChange);
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, display_name: d.display_name || slugToName(d.id),
      description: d.description || '', beneficial: !!d.beneficial,
      color: d.color || '8fd0ff', glyph: d.glyph || '✦' };
    if (d.aura) out.aura = true;
    if (d.decay && d.decay !== 'duration') out.decay = d.decay;
    if (d.decay === 'duration' || !d.decay) out.default_duration = d.default_duration || 2;
    if (d.decay_phase && d.decay_phase !== 'turn_end') out.decay_phase = d.decay_phase;
    out.stacking = d.stacking || 'refresh';
    if (d.stacking === 'stack' || d.decay === 'stacks' || d.decay === 'intercept') out.max_stacks = d.max_stacks || 9;
    if (d.spread && typeof d.spread === 'object') {
      const s = { phase: d.spread.phase || 'turn_start',
        chance: d.spread.chance || 0, decay_chance: d.spread.decay_chance || 0 };
      if (d.spread.to && d.spread.to !== 'adjacent') s.to = d.spread.to;
      if (d.spread.status) s.status = d.spread.status;
      if (d.spread.arrival) s.arrival = d.spread.arrival;
      out.spread = s;
    }
    // Per-stack eval pricing: 0 means absent (the fold's neutral value); adds only —
    // the game loader refuses muls at status level.
    const ev = {};
    for (const k of ['threat', 'exposure', 'value'])
      if (d.eval && d.eval[k] != null && d.eval[k] !== 0) ev[k] = d.eval[k];
    if (Object.keys(ev).length) out.eval = ev;
    out.effects = cleanEffects(d.effects);
    if (d.abilities && d.abilities.length) out.abilities = d.abilities.slice();
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed status'} — ${d.beneficial ? 'buff' : 'debuff'}.`];
    lines.push(`Wears off: ${labelOf('decay', d.decay || 'duration')}; re-apply: ${labelOf('stacking', d.stacking || 'refresh')}.`);
    if (d.spread) lines.push(`Spreads: each stack ${Math.round((d.spread.chance || 0) * 100)}% to `
      + `${d.spread.to === 'ground' ? 'the ground beneath the carrier' : 'an adjacent slot'}`
      + `${d.spread.status ? ' (arriving as ' + d.spread.status + ')' : ''}, else `
      + `${Math.round((d.spread.decay_chance || 0) * 100)}% that flame dies down`
      + `${d.spread.arrival ? '; an arrival deals "' + d.spread.arrival + '" to the occupant' : ''}.`);
    for (const e of d.effects || []) lines.push(describeEffect(e, 'the carrier'));
    for (const a of d.abilities || []) lines.push(`Grants ability while active: ${a}.`);
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    for (const k of ['effects', 'abilities']) if (!d[k]) d[k] = [];
    if (d.glyph == null && d.letter != null) d.glyph = d.letter;   // loader alias
    if (d.default_duration == null) d.default_duration = d.duration != null ? d.duration : 1;
    if (d.beneficial == null) d.beneficial = true;                 // loader default
    return d;
  },
  promptFor(d) {
    return `Small fantasy status emblem icon representing "${d.display_name || slugToName(d.id)}", single centered glowing symbol, painterly style, on a plain solid white background`;
  },
  artNote: 'Installed to assets/ui/status/<id>_status.png — shown on the status pip and in tooltips (pips fall back to glyph + colour without it). Background removal recommended.',
};

// ═════════════════════════════════ ABILITY ══════════════════════════════════
const AbilityEditor = {
  label: 'Ability',
  newItem: () => ({ id: '', display_name: '', description: '', cost: { mana: 1, tap: true }, material: '', effects: [] }),
  form(draft, ctx, onChange) {
    if (!draft.effects) draft.effects = [];
    if (!draft.cost) draft.cost = { mana: 1, tap: true };
    const wrap = el('div');
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
        ),
      ),
      groupBox('Text (tooltip)', locFields(draft, { type: 'ability', typeLabel: 'ability', onChange,
        describeLines: () => (draft.effects || []).map(e => describeEffect(e, 'the holder')) })),
      groupBox('Cost',
        el('div', { class: 'frow' },
          fld('Mana', numInput(draft.cost, 'mana', onChange, { min: 0 }), null, 'narrow'),
          el('div', { class: 'fld' }, checkInput(draft.cost, 'tap', onChange, 'Taps the holder (spends its action for the round)')),
        ),
      ),
      groupBox('Activation',
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, checkInput(draft, 'autocast', onChange,
            'Autocast-capable: shows corner brackets in the tray; the player can arm it (right-click / long-press) and fire by dragging the holder onto a target')),
        ),
      ),
      groupBox('Material (optional)',
        el('div', { class: 'frow' },
          fld('Delivered composition key', textInput(draft, 'material', onChange, 'e.g. pawn, queen, darkness_water'),
            'only for deliver_material abilities: the composition merged/spawned into the picked slot'),
        ),
      ),
      groupBox('Effects (triggers are ignored — they fire on activation)'),
    );
    renderEffectList(wrap.lastChild, draft.effects, fxCtx(ctx, 'the holder'), onChange);
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, display_name: d.display_name || slugToName(d.id), description: d.description || '',
      cost: { mana: (d.cost && d.cost.mana) || 0, tap: !d.cost || d.cost.tap !== false } };
    if (d.autocast) out.autocast = true;
    if (d.material) out.material = d.material;
    out.effects = cleanEffects(d.effects);
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed ability'} — costs ${describeCost(d.cost)}.`];
    if (d.autocast) lines.push('Autocast-capable: can be armed and fired by dragging the holder onto a target.');
    if (d.material) lines.push(`Delivers material: ${d.material}.`);
    for (const e of d.effects || []) lines.push(describeEffect(e, 'the holder'));
    lines.push('Cards hold it via their "Activated abilities" list; statuses can grant it temporarily.');
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.effects) d.effects = [];
    if (!d.cost) d.cost = { mana: 0, tap: true };
    if (d.cost.tap == null) d.cost.tap = true;
    return d;
  },
  promptFor(d) {
    return `Fantasy spell ability icon, ${d.display_name || slugToName(d.id)}, ${d.description || ''}, single centered glowing emblem, painterly style, on a plain solid white background`;
  },
  artNote: 'Installed to assets/abilities/<id>.png — shown on the ability tray entry. Card-format art (portrait, full background).',
};

// ═════════════════════════════════ CHARM ════════════════════════════════════
const CharmEditor = {
  label: 'Charm',
  newItem: () => ({ id: '', display_name: '', description: '', color: 'b8b8c8', letter: '✦',
    targets: 'unit', stats: {}, effects: [] }),
  form(draft, ctx, onChange) {
    if (!draft.effects) draft.effects = [];
    if (!draft.stats) draft.stats = {};
    const wrap = el('div');
    const statFld = (key, label) => fld(label, numInput(draft.stats, key, onChange, { optional: true, placeholder: '—' }), null, 'narrow');
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Pip colour', colorInput(draft, 'color', onChange), null, 'narrow'),
          fld('Pip glyph', textInput(draft, 'letter', onChange, '✦'), null, 'narrow'),
          fld('Attaches to', selectInput(draft, 'targets', [
            { value: 'unit', label: 'units only (combat charms)' },
            { value: 'spell', label: 'spells only' },
            { value: 'any', label: 'any card' },
          ], onChange), 'the King is never eligible'),
        ),
      ),
      groupBox('Text', locFields(draft, { type: 'charm', typeLabel: 'charm', onChange,
        describeLines: () => [
          ...Object.entries(draft.stats || {}).filter(([, v]) => typeof v === 'number' && v !== 0).map(([k, v]) => `${signed(v)} <${k}>`),
          ...(draft.effects || []).map(e => describeEffect(e, 'the charmed card')),
        ] })),
      groupBox('Permanent stat bonuses (leave blank for none)',
        el('div', { class: 'frow' },
          statFld('attack', 'Attack'), statFld('health', 'Health'), statFld('speed', 'Speed'),
          statFld('shield', 'Shield'), statFld('cost', 'Mana cost'),
        ),
      ),
      groupBox('Extra effects merged into the card'),
    );
    renderEffectList(wrap.lastChild, draft.effects, fxCtx(ctx, 'the charmed card'), onChange);
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, display_name: d.display_name, description: d.description || '',
      color: d.color || 'b8b8c8', letter: d.letter || '✦' };
    if (d.targets && d.targets !== 'unit') out.targets = d.targets;
    const stats = {};
    for (const [k, v] of Object.entries(d.stats || {})) if (typeof v === 'number' && v !== 0) stats[k] = v;
    if (Object.keys(stats).length) out.stats = stats;
    if ((d.effects || []).length) out.effects = cleanEffects(d.effects);
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed charm'} — attaches to ${d.targets || 'unit'}s (never the King).`];
    const stats = Object.entries(d.stats || {}).filter(([, v]) => typeof v === 'number' && v !== 0);
    if (stats.length) lines.push('Stat bonuses: ' + stats.map(([k, v]) => `${signed(v)} ${k}`).join(', ') + '.');
    for (const e of d.effects || []) lines.push(describeEffect(e, 'the charmed card'));
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.effects) d.effects = [];
    if (!d.stats) d.stats = {};
    if (!d.targets) d.targets = 'unit';
    return d;
  },
  promptFor(d) {
    return `Tiny fantasy charm trinket icon, ${d.display_name || slugToName(d.id)}, single centered object, painterly style, on a plain solid white background`;
  },
  artNote: 'Reference only — the game renders charm pips from glyph + colour; generated art stays in the tool workspace.',
};

// ═══════════════════════════════ UPGRADE TREE ═══════════════════════════════
const UpgradeEditor = {
  label: 'Upgrade Tree',
  newItem: () => ({ id: '', display_name: '', description: '', color: '8c99d9', nodes: [] }),
  form(draft, ctx, onChange) {
    if (!draft.nodes) draft.nodes = [];
    const wrap = el('div');
    wrap.append(groupBox('Tree',
      el('div', { class: 'frow' },
        idField(draft, onChange, ctx.isNew),
        fld('Accent colour', colorInput(draft, 'color', onChange), null, 'narrow'),
      ),
      locFields(draft, { type: 'upgrade', typeLabel: 'upgrade tree', onChange }),
    ));

    const nodesBox = groupBox('Nodes (row = depth from the top, col = lateral position)');
    wrap.append(nodesBox);
    const renderNodes = () => {
      while (nodesBox.children.length > 1) nodesBox.lastChild.remove();
      draft.nodes.forEach((n, i) => {
        if (!n.requires) n.requires = [];
        if (!n.effects) n.effects = [];
        const otherIds = draft.nodes.filter(x => x !== n && x.id).map(x => x.id);
        // renaming/adding node ids must refresh every node's "Requires" chip set
        const idInput = textInput(n, 'id', onChange, 'e.g. arc_root');
        idInput.addEventListener('blur', () => renderNodes());
        const nodeCard = el('div', { class: 'fx-card' },
          el('div', { class: 'fx-head' },
            el('b', { text: n.display_name || n.id || `node ${i + 1}` }),
            el('div', { class: 'fx-sum' }),
            el('button', { class: 'ghost tiny', text: '✕ remove node', onclick: () => { draft.nodes.splice(i, 1); onChange(); renderNodes(); } })),
          el('div', { class: 'frow' },
            fld('Node id', idInput),
            fld('Icon glyph', textInput(n, 'icon', onChange, '✦'), null, 'narrow'),
          ),
          locFields(n, { type: 'upgrade', typeLabel: 'upgrade node', onChange,
            describeLines: () => (n.effects || []).map(e => describeEffect(e, 'this upgrade')) }),
          el('div', { class: 'frow' },
            fld('Point cost', numInput(n, 'cost', onChange, { min: 1 }), null, 'narrow'),
            fld('Row', numInput(n, 'row', onChange, { min: 0 }), null, 'narrow'),
            fld('Col', numInput(n, 'col', onChange, { min: 0 }), null, 'narrow'),
            el('div', { class: 'fld' }, el('span', { class: 'lab', text: 'Requires (owned first)' }),
              otherIds.length ? chipSet(n.requires, otherIds, onChange) : el('span', { class: 'subtle', text: 'no other nodes yet' })),
          ),
          el('div', { class: 'lab subtle', style: 'margin:6px 0 4px', text: 'Node effects:' }),
        );
        const fxWrap = el('div');
        renderEffectList(fxWrap, n.effects, fxCtx(ctx, 'this upgrade'), onChange);
        nodeCard.append(fxWrap);
        nodesBox.append(nodeCard);
      });
      nodesBox.append(el('button', { class: 'ghost small list-add', text: '+ add node', onclick: () => {
        draft.nodes.push({ id: '', display_name: '', description: '', cost: 1, icon: '✦',
          row: draft.nodes.length, col: 0, requires: [], effects: [] });
        onChange(); renderNodes();
      } }));
    };
    renderNodes();
    return wrap;
  },
  serialize(d) {
    return { id: d.id, display_name: d.display_name, description: d.description || '',
      color: d.color || '8c99d9',
      nodes: (d.nodes || []).map(n => ({
        id: n.id, display_name: n.display_name, description: n.description || '',
        cost: n.cost || 1, icon: n.icon || '✦', row: n.row || 0, col: n.col || 0,
        requires: (n.requires || []).slice(),
        effects: cleanEffects(n.effects),
      })) };
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed tree'} — ${(d.nodes || []).length} node(s).`];
    for (const n of d.nodes || []) {
      lines.push(`● ${n.display_name || n.id} (cost ${n.cost || 1}${(n.requires || []).length ? ', needs ' + n.requires.join('+') : ''}):`);
      for (const e of n.effects || []) lines.push('   ' + describeEffect(e, 'this upgrade'));
    }
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.nodes) d.nodes = [];
    for (const n of d.nodes) { if (!n.requires) n.requires = []; if (!n.effects) n.effects = []; }
    return d;
  },
  promptFor(d) {
    return `Fantasy skill tree emblem, ${d.display_name || slugToName(d.id)}, single centered glowing sigil, painterly style, on a plain solid white background`;
  },
  artNote: 'Installed to assets/ui/upgrades/<id>.png — the tree\'s emblem on the Upgrades screen (nodes themselves stay glyphs). Background removal recommended.',
};

// ═══════════════════════════════ TRIBE ══════════════════════════════════════
// The enemy hub's organizational entity (data/tribes): a tribe's canonical STYLE
// reference — prompt fragment + optional anchor image — steers every member unit's
// art generation; per-unit canonical CONCEPT lives on each card's own art recipe.
const TribeEditor = {
  label: 'Tribe',
  newItem: () => ({ id: '', display_name: '', description: '', style: '', style_ref: '' }),
  form(draft, ctx, onChange) {
    const wrap = el('div');
    const preview = el('img', { class: 'thumb', style: 'max-width:220px; max-height:220px; width:auto; height:auto; border-radius:8px',
      src: draft.style_ref ? '/gameart/' + draft.style_ref : '' });
    preview.hidden = !draft.style_ref;
    preview.onerror = () => { preview.hidden = true; };
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Name', textInput(draft, 'display_name', onChange, 'Slimes')),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Description' }),
            el('textarea', { value: draft.description || '',
              placeholder: 'what this tribe IS — its mechanical identity and flavor, for the hub listing',
              oninput: e => { draft.description = e.target.value; onChange(); } })),
        ),
      ),
      groupBox('Canonical style reference',
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Style fragment' }),
            el('textarea', { value: draft.style || '',
              placeholder: 'the tribe\'s canonical look, as a prompt fragment — automatically joined into every member unit\'s art generation',
              oninput: e => { draft.style = e.target.value; onChange(); } })),
        ),
        el('div', { class: 'frow' },
          fld('Anchor image', textInput(draft, 'style_ref', () => {
            preview.src = draft.style_ref ? '/gameart/' + draft.style_ref : '';
            preview.hidden = !draft.style_ref;
            onChange();
          }, 'assets/cards/enemies/<id>.png'), 'a member unit\'s art that best embodies the tribe\'s look'),
        ),
        el('div', { class: 'frow' }, preview),
      ),
    );
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, display_name: d.display_name };
    if (d.description) out.description = d.description;
    if (d.style) out.style = d.style;
    if (d.style_ref) out.style_ref = d.style_ref;
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed'} — an enemy tribe.`];
    if (d.description) lines.push(d.description);
    lines.push(d.style ? `Canonical style: ${d.style}` : 'No canonical style yet — member art generation uses only the shared style.');
    if (d.style_ref) lines.push(`Anchor image: ${d.style_ref}`);
    return lines;
  },
  promptFor(d) {
    return `Group portrait of the ${d.display_name || slugToName(d.id)} enemy tribe, ${d.style || 'fantasy game enemies'}, banner illustration`;
  },
  artNote: 'Tribes have no in-game art slot — generation here produces workspace reference imagery only.',
};

// ═══════════════════════════════ ENCOUNTER ══════════════════════════════════
const EncounterEditor = {
  label: 'Encounter',
  newItem: () => ({ id: '', node_type: 'combat', tier: '0', min_floor: 0, max_floor: 999, weight: 1, enabled: true,
    enemy_king: '', power_bonus: 0, enemy_pool: [], pick_count: [14, 20], survival_weights: {}, _sw_cards: [],
    gold_reward: [20, 40], mineral_reward: [0, 0], exp_reward: 1, relic_reward: 0, ai: 'default', reward_pool: 'default' }),
  form(draft, ctx, onChange) {
    if (!draft.enemy_pool) draft.enemy_pool = [];
    if (!Array.isArray(draft.pick_count)) draft.pick_count = [14, 20];
    if (!Array.isArray(draft.gold_reward)) draft.gold_reward = [0, 0];
    if (!Array.isArray(draft.mineral_reward)) draft.mineral_reward = [0, 0];
    const wrap = el('div');
    const kings = cardIdOptions(ctx, c => c.is_king);
    const pcObj = { min: draft.pick_count[0], max: draft.pick_count[1] };
    const grObj = { min: draft.gold_reward[0], max: draft.gold_reward[1] };
    const mrObj = { min: draft.mineral_reward[0], max: draft.mineral_reward[1] };
    const syncPc = () => { draft.pick_count = [pcObj.min, pcObj.max]; };
    const syncGr = () => { draft.gold_reward = [grObj.min, grObj.max]; };
    const syncMr = () => { draft.mineral_reward = [mrObj.min, mrObj.max]; };

    wrap.append(
      groupBox('Template',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          // Kind and tier are the 🗂 Fights workspace's two axes — the fight's address. They
          // live here too so opening a fight from anywhere shows where it is filed.
          fld('Kind', selectInput(draft, 'node_type', [
            { value: 'combat', label: 'Normal — the ordinary fights of a run' },
            { value: 'elite', label: 'Elite' }, { value: 'boss', label: 'Boss' },
            { value: 'gimmick', label: 'Gimmick — one unusual idea, Combat Gym only for now' },
            { value: 'test', label: 'Test — Combat Gym only, never map-generated' },
          ], onChange)),
          fld('Complexity tier', selectInput(draft, 'tier', [
            { value: '0', label: 'Unfiled' },
            { value: '1', label: 'T1 — Simple' },
            { value: '2', label: 'T2 — Meat' },
            { value: '3', label: 'T3 — Hard' },
          ], onChange), 'where it lives in 🗂 Fights', 'narrow'),
          fld('Pick weight', numInput(draft, 'weight', onChange, { float: true, step: 0.1, min: 0 }),
            'vs other eligible templates', 'narrow'),
        ),
        el('div', { class: 'frow' },
          fld('Min floor', numInput(draft, 'min_floor', onChange, { min: 0 }), null, 'narrow'),
          fld('Max floor', numInput(draft, 'max_floor', onChange, { min: 0 }), null, 'narrow'),
          fld('Min stage', numInput(draft, 'min_stage', onChange, { min: 1, optional: true, placeholder: '1' }), 'act band (a run has 3 stages)', 'narrow'),
          fld('Max stage', numInput(draft, 'max_stage', onChange, { min: 1, optional: true, placeholder: '999' }), null, 'narrow'),
          fld('Power bonus', numInput(draft, 'power_bonus', onChange, { float: true, step: 0.5, min: 0 }),
            'each point grows enemy stats ~5%', 'narrow'),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, checkInput(draft, 'enabled', onChange,
            'Enabled — untick to retire this template without deleting it (the game skips disabled entries entirely)')),
        ),
      ),
      // organizational label only — groups this encounter under its tribes in the ⚔ hub
      (() => {
        if (!Array.isArray(draft.tribes)) draft.tribes = [];
        const box = groupBox('Tribes (organizational label)');
        const row = el('div', { class: 'frow', style: 'flex-wrap:wrap; gap:6px' });
        for (const t of tribeOptions()) {
          const on = () => draft.tribes.includes(t.value);
          const btn = el('button', { class: 'ghost small' + (on() ? ' active' : ''), text: t.label,
            onclick: e => {
              e.preventDefault();
              if (on()) draft.tribes = draft.tribes.filter(x => x !== t.value);
              else draft.tribes.push(t.value);
              btn.className = 'ghost small' + (on() ? ' active' : '');
              onChange();
            } });
          row.append(btn);
        }
        if (!tribeOptions().length) row.append(el('span', { class: 'subtle', text: 'no tribes authored yet — add them in the ⚔ Encounters tab' }));
        box.append(row);
        return box;
      })(),
      groupBox('Enemy side',
        el('div', { class: 'frow' },
          fld('Enemy King / Captain', kings.length
            ? selectInput(draft, 'enemy_king', kings, onChange, { optional: true, emptyLabel: 'generic crown King (default)' })
            : textInput(draft, 'enemy_king', onChange, 'card id'),
            'do NOT also list it in the pool'),
          // WHO the CPU is in this fight — the eval weights the enemy engine scores with.
          // Authored (and assignable in bulk) in the 🧠 Enemy AI tab; this box is the same
          // key, so an encounter can be pointed at a character without leaving its editor.
          fld('Personality', textInput(draft, 'personality', onChange, 'default'),
            'an id from the 🧠 Enemy AI tab — blank/default = the stock character'),
        ),
      ),
      groupBox('Battle size & rewards',
        el('div', { class: 'frow' },
          fld('Deck size min', numInput(pcObj, 'min', () => { syncPc(); onChange(); }, { min: 1 }), null, 'narrow'),
          fld('Deck size max', numInput(pcObj, 'max', () => { syncPc(); onChange(); }, { min: 1 }), 'cards sampled with replacement', 'narrow'),
          fld('Gold min', numInput(grObj, 'min', () => { syncGr(); onChange(); }, { min: 0 }), null, 'narrow'),
          fld('Gold max', numInput(grObj, 'max', () => { syncGr(); onChange(); }, { min: 0 }), null, 'narrow'),
        ),
        el('div', { class: 'frow' },
          fld('Mineral min', numInput(mrObj, 'min', () => { syncMr(); onChange(); }, { min: 0 }), 'extra Magic Mineral on top of the tool default', 'narrow'),
          fld('Mineral max', numInput(mrObj, 'max', () => { syncMr(); onChange(); }, { min: 0 }), null, 'narrow'),
        ),
        el('div', { class: 'frow' },
          fld('Experience', numInput(draft, 'exp_reward', onChange, { min: 0 }), 'profile XP toward upgrade points', 'narrow'),
          fld('Relic drop chance', numInput(draft, 'relic_reward', onChange, { float: true, step: 0.1, min: 0, max: 1 }), '0–1', 'narrow'),
          fld('AI', textInput(draft, 'ai', onChange, 'default'), null, 'narrow'),
          fld('Reward pool', textInput(draft, 'reward_pool', onChange, 'default'), null, 'narrow'),
        ),
      ),
    );

    // Weight = this unit's SHARE of the deck; From power = the difficulty it is ANCHORED to,
    // i.e. when it joins the roster at all. The deck is apportioned to the weights rather than
    // rolled against them (2026-07-30), and nothing reweights the pool by cost or depth, so a
    // weight means exactly what it says at every difficulty.
    const poolBox = groupBox('Enemy card pool (shares of the deck)');
    wrap.append(poolBox);
    const cardOpts = cardIdOptions(ctx, c => !c.is_king);
    const renderPool = () => {
      while (poolBox.children.length > 1) poolBox.lastChild.remove();
      const table = el('table', { class: 'mini' },
        el('tr', null, el('th', { text: 'Card' }), el('th', { text: 'Weight' }),
          el('th', { text: 'From power' }), el('th')));
      draft.enemy_pool.forEach((p, i) => {
        table.append(el('tr', null,
          el('td', null, selectInput(p, 'id', cardOpts, onChange)),
          el('td', { style: 'width:90px' }, numInput(p, 'weight', onChange, { float: true, step: 0.5, min: 0 })),
          el('td', { style: 'width:100px' }, numInput(p, 'min_power', onChange, { float: true, step: 1, min: 0, placeholder: '0', optional: true })),
          el('td', { style: 'width:40px' }, el('button', { class: 'ghost tiny', text: '✕', onclick: () => {
            draft.enemy_pool.splice(i, 1); onChange(); renderPool();
          } })),
        ));
      });
      poolBox.append(table,
        el('div', { class: 'hint', text: 'Weight is a SHARE, not a chance: the deck is divided up '
          + 'in proportion (weight ÷ total of the unlocked entries), so every fight lands within '
          + 'a card of the same mix. 0 = not in this fight.' }),
        el('div', { class: 'hint', text: 'From power: this unit stays out of the fight until the '
          + 'encounter reaches that power (blank/0 = from the very first fight). Power runs 0 at '
          + 'the first fight up to roughly the deepest floor at the final boss.' }),
        el('button', { class: 'ghost small list-add', text: '+ add card', onclick: () => {
          draft.enemy_pool.push({ id: (cardOpts[0] && cardOpts[0].value) || '', weight: 1 });
          onChange(); renderPool();
        } }));
    };
    renderPool();

    // ── survival weights: how much the enemy engine protects each kind of unit ──
    // Blank = the stock value (shown as the placeholder). The engine resolves a unit
    // through card id → captain → role → default, so both tables live here.
    if (!draft.survival_weights) draft.survival_weights = {};
    if (!Array.isArray(draft._sw_cards)) draft._sw_cards = [];
    const swBox = groupBox('Enemy engine — survival weights (this fight only)');
    const swField = (key, label, hint) => fld(label,
      numInput(draft.survival_weights, key, onChange,
        { float: true, step: 0.05, min: 0, optional: true, placeholder: STOCK_SURVIVAL_WEIGHTS[key] + '' }),
      hint, 'narrow');
    swBox.append(
      el('div', { class: 'hint', text: 'What the CPU will spend position — and its Captain\'s body — to keep alive. Higher = protect harder. Blank keeps the stock value shown in the box. Weights are RELATIVE: raising everything changes nothing, the ratios are the behaviour.' }),
      el('div', { class: 'frow' },
        swField('captain', 'Captain', 'the King. 1.0 = reckless sponge, 1.75 = shares damage yet commits to retreating, 2.5 = total coward'),
        swField('default', 'Untagged', 'any unit with no role tag'),
      ),
      el('div', { class: 'frow' },
        ...UNIT_ROLES.map(r => swField(r.value, r.label.split(' — ')[0])),
      ),
    );
    const swCardOpts = cardIdOptions(ctx);
    const renderSwCards = () => {
      while (swBox.children.length > 4) swBox.lastChild.remove();
      const table = el('table', { class: 'mini' },
        el('tr', null, el('th', { text: 'Specific card' }), el('th', { text: 'Weight' }), el('th')));
      draft._sw_cards.forEach((p, i) => {
        table.append(el('tr', null,
          el('td', null, selectInput(p, 'id', swCardOpts, onChange)),
          el('td', { style: 'width:90px' }, numInput(p, 'weight', onChange, { float: true, step: 0.05, min: 0 })),
          el('td', { style: 'width:40px' }, el('button', { class: 'ghost tiny', text: '✕', onclick: () => {
            draft._sw_cards.splice(i, 1); onChange(); renderSwCards();
          } })),
        ));
      });
      swBox.append(table, el('button', { class: 'ghost small list-add', text: '+ override one card', onclick: () => {
        draft._sw_cards.push({ id: (swCardOpts[0] && swCardOpts[0].value) || '', weight: 0.5 });
        onChange(); renderSwCards();
      } }));
    };
    renderSwCards();
    wrap.append(swBox);
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, node_type: d.node_type, min_floor: d.min_floor || 0, max_floor: d.max_floor == null ? 999 : d.max_floor,
      weight: d.weight == null ? 1 : d.weight };
    if (d.min_stage != null && d.min_stage !== 1) out.min_stage = d.min_stage;
    if (d.max_stage != null && d.max_stage !== 999) out.max_stage = d.max_stage;
    if (d.enemy_king) out.enemy_king = d.enemy_king;
    // The complexity tier it is filed into (🗂 Fights). The select hands back a string, so
    // it is coerced here — the game reads an int, and 0/absent means unfiled, which keeps
    // every un-filed encounter file byte-identical.
    const tier = parseInt(d.tier, 10) || 0;
    if (tier) out.tier = tier;
    // absent = the stock character, so "default" is never written — that keeps every
    // encounter file byte-identical until a fight is genuinely given its own personality
    if (d.personality && d.personality !== 'default') out.personality = d.personality;
    if (d.power_bonus) out.power_bonus = d.power_bonus;
    if (d.tribes && d.tribes.length) out.tribes = d.tribes.slice();
    // min_power is written only when a unit is actually anchored — an absent key means
    // "from the first fight", which keeps every existing encounter file byte-identical.
    out.enemy_pool = (d.enemy_pool || []).map(p => {
      const e = { id: p.id, weight: p.weight == null ? 1 : p.weight };
      if (p.min_power) e.min_power = p.min_power;
      return e;
    });
    out.pick_count = d.pick_count.slice(0, 2);
    if (d.gold_reward && (d.gold_reward[0] || d.gold_reward[1])) out.gold_reward = d.gold_reward.slice(0, 2);
    if (d.mineral_reward && (d.mineral_reward[0] || d.mineral_reward[1])) out.mineral_reward = d.mineral_reward.slice(0, 2);
    if (d.exp_reward != null) out.exp_reward = d.exp_reward;
    if (d.ai && d.ai !== 'default') out.ai = d.ai; else out.ai = 'default';
    out.reward_pool = d.reward_pool || 'default';
    if (d.relic_reward) out.relic_reward = d.relic_reward;
    // `enabled` is written only when retiring the template — an absent key means enabled,
    // and that keeps every existing encounter file untouched.
    if (d.enabled === false) out.enabled = false;
    // Role weights first, then per-card overrides (the engine looks up card id ahead of role).
    // 0 is a real weight ("do not protect this at all"), so this tests PRESENCE, not truthiness.
    const sw = {};
    for (const k of Object.keys(d.survival_weights || {})) {
      const v = d.survival_weights[k];
      if (v != null && v !== '') sw[k] = v;
    }
    for (const p of d._sw_cards || []) if (p.id && p.weight != null && p.weight !== '') sw[p.id] = p.weight;
    if (Object.keys(sw).length) out.survival_weights = sw;
    return out;
  },
  summarize(d) {
    const KIND_WORD = { combat: 'normal', elite: 'elite', boss: 'boss', gimmick: 'gimmick', test: 'test' };
    const TIER_WORD = { 1: 'T1 (simple)', 2: 'T2 (meat)', 3: 'T3 (hard)' };
    const tier = parseInt(d.tier, 10) || 0;
    const filed = tier ? ` — filed at ${TIER_WORD[tier]}`
      : (d.node_type === 'combat' || d.node_type === 'elite' || d.node_type === 'boss') ? ' — UNFILED (no complexity tier)' : '';
    const lines = [`${d.id || 'Unnamed'} — a ${KIND_WORD[d.node_type] || d.node_type} fight on floors ${d.min_floor || 0}–${d.max_floor == null ? 999 : d.max_floor}${filed}.`];
    if (d.tribes && d.tribes.length) lines.push(`Tribes: ${d.tribes.join(', ')}.`);
    lines.push(`Enemy King: ${d.enemy_king || 'generic crown King'}${d.power_bonus ? `, power +${d.power_bonus}` : ''}.`);
    if (d.personality && d.personality !== 'default')
      lines.push(`Fought by the "${d.personality}" personality (🧠 Enemy AI) — its eval weights, not the stock ones.`);
    const anchored = (d.enemy_pool || []).filter(p => p.min_power);
    const anchorNote = anchored.length
      ? ` ${anchored.map(p => `${p.id} joins at power ${p.min_power}`).join('; ')}.`
      : '';
    lines.push(`Deck: ${d.pick_count[0]}–${d.pick_count[1]} cards from ${(d.enemy_pool || []).length} pool entries.${anchorNote}`);
    const g = d.gold_reward || [0, 0];
    const m = d.mineral_reward || [0, 0];
    const mineral = (m[0] || m[1]) ? `, ${m[0]}–${m[1]} extra mineral` : '';
    lines.push(`Win: ${g[0]}–${g[1]} gold${mineral}, ${d.exp_reward || 0} XP${d.relic_reward ? `, ${Math.round(d.relic_reward * 100)}% relic drop` : ''}.`);
    const sw = Object.entries(d.survival_weights || {}).concat((d._sw_cards || []).map(p => [p.id, p.weight]));
    if (sw.length) lines.push(`Enemy engine protects: ${sw.map(([k, v]) => `${k} ${v}`).join(', ')} (other kinds keep stock weights).`);
    if (d.node_type === 'test') lines.push('Test template — reachable only from the Combat Gym, never generated on a map.');
    if (d.enabled === false) lines.push('DISABLED — the game skips this template.');
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.enemy_pool) d.enemy_pool = [];
    if (!Array.isArray(d.pick_count)) d.pick_count = [1, 1];
    if (!Array.isArray(d.gold_reward)) d.gold_reward = [0, 0];
    if (!Array.isArray(d.mineral_reward)) d.mineral_reward = [0, 0];
    if (d.weight == null) d.weight = 1;
    if (d.exp_reward == null) d.exp_reward = 1;
    d.enabled = d.enabled !== false;   // absent = enabled
    d.tier = String(d.tier || 0);      // the tier select works in strings; 0 = unfiled
    // Split the flat survival_weights map back into its two editors: known role keys
    // (plus captain/default) drive the fixed row, anything else is a per-card override.
    const known = new Set(['captain', 'default', ...UNIT_ROLES.map(r => r.value)]);
    const sw = d.survival_weights || {};
    d.survival_weights = {};
    d._sw_cards = [];
    for (const k of Object.keys(sw)) {
      if (known.has(k)) d.survival_weights[k] = sw[k];
      else d._sw_cards.push({ id: k, weight: sw[k] });
    }
    return d;
  },
  promptFor(d) {
    return `Fantasy battle scene banner, ${slugToName(d.id)}, painterly style, dramatic lighting`;
  },
  artNote: 'Reference only — encounters have no art slot in the game.',
};

// ═════════════════════════════ MAP NODE WEIGHTS ═════════════════════════════
const NodeWeightsEditor = {
  label: 'Map Node Weights',
  newItem: () => ({ id: '', bands: [{ min_floor: 1, max_floor: 999, weights: { combat: 0.45, rest: 0.2, event: 0.15, shop: 0.2 } }] }),
  form(draft, ctx, onChange) {
    if (!draft.bands) draft.bands = [];
    const wrap = el('div');
    wrap.append(groupBox('File',
      el('div', { class: 'frow' }, idField(draft, onChange, ctx.isNew)),
      el('div', { class: 'hint', text: 'Each band sets the odds of node types on the floors it covers. The FIRST matching band wins — the game also ships data/map/node_weights.json, so overlapping bands may be shadowed by it (load order is alphabetical by filename; installed files are named tool_nodeweights_<id>.json). Weights are relative, they need not sum to 1. Floor 0 is always Combat; the last floor Boss; second-to-last Elite.' }),
    ));
    const bandsBox = groupBox('Floor bands');
    wrap.append(bandsBox);
    const NODE_TYPES = ['combat', 'rest', 'event', 'shop'];
    const renderBands = () => {
      while (bandsBox.children.length > 1) bandsBox.lastChild.remove();
      draft.bands.forEach((b, i) => {
        if (!b.weights) b.weights = {};
        bandsBox.append(el('div', { class: 'fx-card' },
          el('div', { class: 'frow' },
            fld('From floor', numInput(b, 'min_floor', onChange, { min: 0 }), null, 'narrow'),
            fld('To floor', numInput(b, 'max_floor', onChange, { min: 0 }), null, 'narrow'),
            ...NODE_TYPES.map(t => fld(t, numInput(b.weights, t, onChange, { float: true, step: 0.05, min: 0, optional: true, placeholder: '0' }), null, 'narrow')),
            el('div', { class: 'fld narrow', style: 'justify-content:flex-end' },
              el('button', { class: 'ghost tiny', text: '✕', onclick: () => { draft.bands.splice(i, 1); onChange(); renderBands(); } })),
          ),
        ));
      });
      bandsBox.append(el('button', { class: 'ghost small list-add', text: '+ add band', onclick: () => {
        draft.bands.push({ min_floor: 1, max_floor: 999, weights: { combat: 0.45, rest: 0.2, event: 0.15, shop: 0.2 } });
        onChange(); renderBands();
      } }));
    };
    renderBands();
    return wrap;
  },
  serialize(d) {
    return { id: d.id, bands: (d.bands || []).map(b => {
      const weights = {};
      for (const [k, v] of Object.entries(b.weights || {})) if (typeof v === 'number' && v > 0) weights[k] = v;
      return { min_floor: b.min_floor || 0, max_floor: b.max_floor == null ? 999 : b.max_floor, weights };
    }) };
  },
  summarize(d) {
    return (d.bands || []).map(b => {
      const w = Object.entries(b.weights || {}).filter(([, v]) => v > 0);
      const total = w.reduce((s, [, v]) => s + v, 0) || 1;
      return `Floors ${b.min_floor}–${b.max_floor}: ` + w.map(([k, v]) => `${k} ${Math.round(v / total * 100)}%`).join(', ') + '.';
    });
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.bands) d.bands = [];
    return d;
  },
  promptFor() { return 'Fantasy map parchment, painterly style'; },
  artNote: 'Reference only — node weights have no art.',
};

// ═════════════════════════════════ SOUND ════════════════════════════════════
// One entry per sound EVENT the game will ever make. The library is exhaustive by design:
// every eventual sound already has a definition — concept (design intent) + prompt (AI
// sound-generation text) — and the game plays a procedural placeholder for any event whose
// asset doesn't exist yet, so hookups never wait on audio production.
const SOUND_CATEGORIES = ['ui', 'card', 'combat', 'magic', 'resource', 'map', 'economy', 'lab', 'meta', 'ambient', 'music'];

// The in-browser twin of the game's placeholder synth (Sfx._placeholder): same id→pitch hash,
// same decaying-sine shape — auditioning here is hearing what the game will play.
function soundPlaceholderHash(id) {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) % 99991;
  return h;
}
function playSoundPlaceholder(d) {
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  const freq = 240 + (soundPlaceholderHash(d.id || '') % 720);
  const secs = d.loop ? 1.2 : 0.14;
  const now = ctx.currentTime;
  for (const [mult, amp] of [[1, 1], [2, 0.25]]) {
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.frequency.value = freq * mult;
    if (d.loop) {
      gain.gain.setValueAtTime(0.12 * amp, now);
    } else {
      gain.gain.setValueAtTime(0.3 * amp, now);
      gain.gain.exponentialRampToValueAtTime(0.001, now + secs);
    }
    osc.connect(gain).connect(ctx.destination);
    osc.start(now);
    osc.stop(now + secs);
  }
  setTimeout(() => ctx.close(), secs * 1000 + 100);
}

// ── AI SFX generation (local AudioGen server via the Tool backend) ───────────
// Generate candidate wavs from the entry's prompt, audition them, install one as
// THE asset (assets/sound/<id>.wav — also stamps the entry's `file` field).
function soundGenBox(draft, ctx, onChange) {
  const status = el('span', { class: 'lab', text: '' });
  const list = el('div');
  const durIn = el('input', { type: 'number', value: '2', min: '0.5', max: '10', step: '0.5' });
  const cntIn = el('input', { type: 'number', value: '3', min: '1', max: '8', step: '1' });

  const renderList = candidates => {
    list.innerHTML = '';
    for (const f of candidates) {
      list.append(el('div', { class: 'frow' },
        el('button', { class: 'ghost', text: '▶', title: 'Audition this candidate',
          onclick: e => { e.preventDefault();
            new Audio('/sfxwav/' + encodeURIComponent(draft.id) + '/' + encodeURIComponent(f)).play(); } }),
        el('span', { class: 'lab', text: f }),
        el('button', { class: 'ghost', text: '✓ Use', title: 'Install as assets/sound/' + draft.id + '.wav',
          onclick: async e => { e.preventDefault();
            try {
              const out = await api('/api/sfx/install', { id: draft.id, file: f });
              draft.file = out.file; onChange();
              status.textContent = 'Installed as assets/sound/' + out.file;
            } catch (err) { status.textContent = err.message; } } }),
        el('button', { class: 'ghost', text: '🗑', title: 'Discard candidate',
          onclick: async e => { e.preventDefault();
            const out = await api('/api/sfx/candidate-delete', { id: draft.id, file: f });
            renderList(out.candidates); } }),
      ));
    }
  };

  if (draft.id) api('/api/sfx/candidates?id=' + encodeURIComponent(draft.id))
    .then(out => renderList(out.candidates)).catch(() => {});

  return groupBox('AI generation — local AudioGen',
    el('div', { class: 'frow' },
      el('div', { class: 'fld narrow' }, el('span', { class: 'lab', text: 'Duration (s)' }), durIn),
      el('div', { class: 'fld narrow' }, el('span', { class: 'lab', text: 'Variants' }), cntIn),
      el('button', { class: 'ghost', text: '🎵 Generate',
        title: 'Generate candidate wavs from the AI prompt above (needs tools/audiogen server running)',
        onclick: async e => {
          e.preventDefault();
          if (!draft.id) { status.textContent = 'Save an id first'; return; }
          if (!(draft.prompt || '').trim()) { status.textContent = 'Write an AI prompt first'; return; }
          const btn = e.target; btn.disabled = true;
          status.textContent = 'Generating… (first call after server start is slower)';
          try {
            const out = await api('/api/sfx/generate', { id: draft.id, prompt: draft.prompt,
              duration: parseFloat(durIn.value) || 2, count: parseInt(cntIn.value, 10) || 3 });
            status.textContent = `Done in ${out.seconds}s`;
            renderList(out.candidates);
          } catch (err) { status.textContent = err.message; }
          btn.disabled = false;
        } }),
      status,
    ),
    list,
  );
}

const SoundEditor = {
  label: 'Sound',
  newItem: () => ({ id: '', display_name: '', category: 'ui', concept: '', prompt: '',
    file: '', dir: '', volume_db: 0, loop: false, enabled: true }),
  form(draft, ctx, onChange) {
    const wrap = el('div');
    const hasFile = () => !!(draft.file || '').trim();
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Name', textInput(draft, 'display_name', onChange)),
          fld('Category', selectInput(draft, 'category', SOUND_CATEGORIES.map(v => ({ value: v, label: v })), onChange), null, 'narrow'),
        ),
      ),
      groupBox('Sound design',
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Concept — what this moment is and how it should feel' }),
            el('textarea', { value: draft.concept || '', oninput: e => { draft.concept = e.target.value; onChange(); } })),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'AI generation prompt — ready-to-paste text for a sound generator' }),
            el('textarea', { value: draft.prompt || '', oninput: e => { draft.prompt = e.target.value; onChange(); } })),
        ),
      ),
      soundGenBox(draft, ctx, onChange),
      groupBox('Playback',
        el('div', { class: 'frow' },
          el('div', { class: 'fld' }, checkInput(draft, 'enabled', onChange,
            'Enabled — unticked = PARKED: no live cue site yet (kept as visible backlog, never deleted)')),
        ),
        el('div', { class: 'frow' },
          fld('Asset file', textInput(draft, 'file', onChange, '(empty = placeholder synth)'),
            'bare filename inside assets/sound/ — .mp3/.ogg/.wav'),
          fld('Random pool folder', textInput(draft, 'dir', onChange, 'e.g. music/combat'),
            'folder inside assets/ — each time the event starts, ONE member is drawn at random (overrides Asset file)'),
          fld('Volume trim (dB)', numInput(draft, 'volume_db', onChange, { step: 1, float: true, min: -60, max: 12 }),
            '0 = as authored, negative = gentler', 'narrow'),
          el('div', { class: 'fld' }, checkInput(draft, 'loop', onChange, 'Looped bed (drone / ambience / music)')),
        ),
        el('div', { class: 'frow' },
          fld('Crossfade (s)', numInput(draft, 'fade', onChange, { step: 0.1, float: true, min: 0.05, max: 10 }),
            'looped mp3/ogg only: seam blend length, also the start/stop fade', 'narrow'),
          fld('Edge trim (s)', numInput(draft, 'trim', onChange, { step: 0.1, float: true, min: 0, max: 10 }),
            'looped mp3/ogg only: seconds cut off BOTH asset ends', 'narrow'),
        ),
        el('div', { class: 'frow' },
          el('button', { class: 'ghost', text: '▶ Preview placeholder',
            title: 'The synth blip the game plays while this event has no asset (same pitch as in game)',
            onclick: e => { e.preventDefault(); playSoundPlaceholder(draft); } }),
          el('button', { class: 'ghost', text: '▶ Play asset',
            title: hasFile() ? 'Play assets/sound/' + draft.file : 'No asset file set',
            onclick: e => {
              e.preventDefault();
              if (!hasFile()) return;
              new Audio('/gamesound/' + encodeURIComponent(draft.file.trim())).play();
            } }),
        ),
      ),
    );
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, display_name: d.display_name || slugToName(d.id),
      category: d.category || 'ui', concept: d.concept || '', prompt: d.prompt || '' };
    if (d.enabled === false) out.enabled = false;   // parked — visible backlog
    if ((d.file || '').trim()) out.file = d.file.trim();
    if ((d.dir || '').trim()) out.dir = d.dir.trim();
    if (d.volume_db) out.volume_db = d.volume_db;
    if (d.loop) out.loop = true;
    // fade/trim ship only when they differ from the game's defaults (1.5 / 0.5)
    if (d.fade != null && d.fade !== 1.5) out.fade = d.fade;
    if (d.trim != null && d.trim !== 0.5) out.trim = d.trim;
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed sound'} — ${d.category || 'ui'} ${d.loop ? 'loop' : 'one-shot'}.`];
    if (d.enabled === false) lines.push('PARKED (enabled: false) — no live cue site yet; the game skips it at load.');
    if (d.dir) lines.push(`Random pool: draws one file from assets/${d.dir}/ each time it starts${d.volume_db ? ` at ${d.volume_db} dB` : ''}.`);
    else lines.push(d.file ? `Plays assets/sound/${d.file}${d.volume_db ? ` at ${d.volume_db} dB` : ''}.`
      : 'No asset yet — the game plays a placeholder synth blip for this event.');
    if (d.concept) lines.push(d.concept);
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (d.enabled == null) d.enabled = true;
    if (d.fade == null) d.fade = 1.5;
    if (d.trim == null) d.trim = 0.5;
    return d;
  },
  promptFor(d) {
    return `Concept illustration of a sound: ${d.display_name || slugToName(d.id)}, ${d.concept || ''}, abstract audio waveform art`;
  },
  artNote: 'Reference only — sounds have no art slot; assets are produced from the AI prompt in an audio generator.',
};

// ═════════════════════════════════ VFX ══════════════════════════════════════
// One entry per visual effect the game will ever show — played BY ID on any Control via the
// Vfx autoload. `behavior` picks the procedural primitive, `params` skin it; `renderer` is
// the future asset-expansion seam ("procedural" only today). Placeholder entries (no designed
// look yet) are clearly flagged and mutable in game via F8 / DevFlags.placeholder_vfx.
const VFX_CATEGORIES = ['ui', 'card', 'combat', 'status', 'resource', 'map', 'economy', 'lab', 'meta', 'screen'];
const VFX_BEHAVIORS = ['flash', 'pulse', 'pop', 'shake', 'ring', 'sparkle', 'glint', 'glow',
  'float_label', 'burst', 'travel', 'reticle', 'dissolve', 'radiance', 'emit'];
const VFX_SUSTAINED = ['glow', 'pulse', 'sparkle', 'radiance', 'emit'];
// 'custom' = an effect class registered in-game via Vfx.register_custom. 'filter' = the look is
// a RenderFilter (its own tab); the VFX entry then owns only WHEN it runs and how it animates.
const VFX_RENDERERS = ['procedural', 'custom', 'filter'];
// What a "radiance" is shaped LIKE. Blank keeps the primitive's own default (rect).
const VFX_SHAPES = [{ value: '', label: '(default — rect)' },
  { value: 'rect', label: 'rect — traces the target’s box' },
  { value: 'radial', label: 'radial — blooms from its centre' }];
const FILTER_LAYERS = ['behind', 'above', 'overlay'];
const FILTER_SOURCES = ['texture', 'rounded_rect'];

// Editor for a flat "shader uniform name -> number|hex colour" dictionary. Render filters key
// their params by uniform name precisely so there is no mapping table to keep in sync with the
// shader, which means the set of keys is per-filter and cannot be a fixed set of fields.
// `skip` hides reserved keys the caller renders itself (e.g. a VFX entry's filter/animate).
function uniformParamsBox(params, onChange, skip) {
  const box = el('div');
  const hidden = skip || [];
  const rebuild = () => {
    box.textContent = '';
    for (const key of Object.keys(params)) {
      if (hidden.includes(key)) continue;
      const isColor = typeof params[key] === 'string';
      // Key renames commit on blur, not per keystroke — rebuilding mid-type would steal focus.
      const keyInput = el('input', { type: 'text', value: key, class: 'uniform-key',
        onchange: e => {
          const next = e.target.value.trim();
          if (!next || next === key) { e.target.value = key; return; }
          const copy = {};
          for (const k of Object.keys(params)) copy[k === key ? next : k] = params[k];
          for (const k of Object.keys(params)) delete params[k];
          Object.assign(params, copy);
          onChange(); rebuild();
        } });
      const typeSel = el('select', {
        onchange: e => {
          params[key] = e.target.value === 'colour' ? 'ffffff' : 0;
          onChange(); rebuild();
        } },
        el('option', { value: 'number', text: 'number', selected: !isColor }),
        el('option', { value: 'colour', text: 'colour', selected: isColor }));
      const valInput = isColor
        ? colorInput(params, key, onChange)
        : numInput(params, key, onChange, { step: 0.1, float: true });
      box.append(el('div', { class: 'frow' },
        fld('Uniform', keyInput, null, 'narrow'),
        fld('Type', typeSel, null, 'narrow'),
        fld('Value', valInput, null, 'narrow'),
        el('button', { class: 'ghost', text: '✕', title: 'Remove this uniform',
          onclick: e => { e.preventDefault(); delete params[key]; onChange(); rebuild(); } })));
    }
    box.append(el('div', { class: 'frow' },
      el('button', { class: 'ghost', text: '+ Add uniform',
        onclick: e => {
          e.preventDefault();
          let n = 1, k = 'uniform_1';
          while (Object.prototype.hasOwnProperty.call(params, k)) k = 'uniform_' + (++n);
          params[k] = 0;
          onChange(); rebuild();
        } })));
  };
  rebuild();
  return box;
}

// A rough in-browser sketch of each procedural primitive, animated on a demo box — enough to
// judge colour and character; the game's tweens are the authority.
function playVfxPreview(stage, d) {
  stage.replaceChildren();
  const color = '#' + (/^[0-9a-fA-F]{6}$/.test((d.params || {}).color || '') ? d.params.color : 'ffd94d');
  const box = el('div', { class: 'vfx-demo-box' });
  stage.append(box);
  const scale = (d.params || {}).scale || 1;
  const dur = ((d.params || {}).duration || 0.4) * 1000;
  const overlay = (styles) => {
    const o = el('div', { class: 'vfx-demo-overlay' });
    Object.assign(o.style, styles);
    stage.append(o);
    return o;
  };
  const anim = (node, frames, ms, cleanup = true) => {
    const a = node.animate(frames, { duration: ms, easing: 'ease-out' });
    if (cleanup) a.onfinish = () => node.remove();
    return a;
  };
  switch (d.behavior) {
    case 'flash': case 'glint':
      anim(overlay({ inset: '18%', background: color, opacity: 0.7 }), [{ opacity: 0.7 }, { opacity: 0 }], dur || 300);
      break;
    case 'pulse': case 'glow': {
      // Sustained states loop a few breaths so the character reads; one-shots swell once.
      const o = overlay({ inset: '10%', background: color, filter: 'blur(14px)', opacity: 0 });
      o.animate([{ opacity: 0.08 }, { opacity: 0.45 }, { opacity: 0.08 }],
        { duration: (dur || 900) * 2, iterations: d.sustained ? 3 : 1 }).onfinish = () => o.remove();
      break;
    }
    case 'pop':
      box.animate([{ transform: 'scale(1)' }, { transform: `scale(${1 + 0.18 * scale})` }, { transform: 'scale(1)' }], { duration: dur || 300, easing: 'cubic-bezier(.3,1.6,.6,1)' });
      break;
    case 'shake':
      box.animate([0, 1, -1, 1, -1, 0].map(v => ({ transform: `translateX(${v * 6 * scale}px)` })), { duration: dur || 280 });
      break;
    case 'ring':
      anim(overlay({ inset: '30%', border: `3px solid ${color}`, borderRadius: '50%', opacity: 1 }),
        [{ transform: 'scale(0.3)', opacity: 1 }, { transform: `scale(${1.6 * scale})`, opacity: 0 }], dur || 400);
      break;
    case 'sparkle': case 'burst':
      for (let i = 0; i < 8; i++) {
        const p = overlay({ left: '50%', top: '50%', width: '7px', height: '7px', background: color, transform: 'rotate(45deg)' });
        const a = d.behavior === 'burst' ? (Math.PI * 2 * i / 8) : (Math.random() * Math.PI * 2);
        const r = d.behavior === 'burst' ? 60 * scale : 30;
        const dy = d.behavior === 'sparkle' ? -30 : Math.sin(a) * r;
        anim(p, [{ transform: 'translate(0,0) rotate(45deg)', opacity: 1 },
          { transform: `translate(${Math.cos(a) * r}px, ${dy}px) rotate(45deg)`, opacity: 0 }], dur || 450);
      }
      break;
    case 'float_label': {
      const l = overlay({ left: '50%', top: '40%', color, fontWeight: '700', fontSize: '22px' });
      l.textContent = '-3';
      anim(l, [{ transform: 'translateY(0)', opacity: 1 }, { transform: 'translateY(-40px)', opacity: 0 }], dur || 800);
      break;
    }
    case 'travel': {
      const p = overlay({ left: '4%', top: '46%', width: '14px', height: '14px', background: color, borderRadius: '50%' });
      anim(p, [{ transform: 'translateX(0)' }, { transform: 'translateX(200px)' }], dur || 300);
      setTimeout(() => playVfxPreview(stage, Object.assign({}, d, { behavior: 'burst' })), dur || 300);
      break;
    }
    case 'reticle':
      anim(overlay({ inset: '14%', border: `3px solid ${color}`, opacity: 1 }),
        [{ transform: 'scale(1.4)', opacity: 0.4 }, { transform: 'scale(1)', opacity: 1 }, { opacity: 0 }], dur || 400);
      break;
    case 'radiance': {
      // The one primitive whose SHAPE is authorable, so the sketch has to show which one is on —
      // a rect halo and a radial bloom read as completely different cues on the same target.
      const radial = (d.params || {}).shape === 'radial';
      const o = overlay(radial
        ? { left: '50%', top: '50%', width: `${90 * scale}px`, height: `${90 * scale}px`,
          marginLeft: `${-45 * scale}px`, marginTop: `${-45 * scale}px`, borderRadius: '50%',
          background: `radial-gradient(circle, ${color} 0%, transparent 70%)`, opacity: 0 }
        : { inset: '12%', background: color, borderRadius: `${14 * scale}px`,
          filter: `blur(${9 * scale}px)`, opacity: 0 });
      o.animate([{ opacity: 0 }, { opacity: radial ? 0.95 : 0.5 }, { opacity: 0 }],
        { duration: dur || 500, iterations: d.sustained ? 3 : 1 }).onfinish = () => o.remove();
      break;
    }
    case 'dissolve':
      anim(overlay({ inset: '18%', background: color, opacity: 0 }),
        [{ opacity: 0 }, { opacity: 0.75 }, { opacity: 0 }], dur || 500);
      break;
  }
}

// The "look" half of a procedural VFX entry: pick a primitive, skin it.
function vfxProceduralLook(draft, ctx, onChange) {
  let stage;
  const box = groupBox('Look (procedural renderer)',
    el('div', { class: 'frow' },
      fld('Behavior', selectInput(draft, 'behavior', VFX_BEHAVIORS.map(v => ({ value: v, label: v })), onChange), 'the primitive this effect rides', 'narrow'),
      el('div', { class: 'fld' }, checkInput(draft, 'sustained', onChange, `Sustained state (attach/detach; needs ${VFX_SUSTAINED.join('/')})`)),
    ),
    el('div', { class: 'frow' },
      fld('Colour', colorInput(draft.params, 'color', onChange), null, 'narrow'),
      fld('Scale', numInput(draft.params, 'scale', onChange, { step: 0.1, float: true, min: 0.2, max: 4, optional: true }), 'size/intensity multiplier', 'narrow'),
      fld('Duration (s)', numInput(draft.params, 'duration', onChange, { step: 0.05, float: true, min: 0.05, max: 5, optional: true }), 'blank = behavior default', 'narrow'),
      fld('Shape', selectInput(draft.params, 'shape', VFX_SHAPES.map(v => ({ value: v.value, label: v.label })), onChange),
        'radiance only — rect traces the target’s box (the target IS the light), radial blooms from its centre (light comes OUT of it)', 'narrow'),
    ),
    el('div', { class: 'frow' },
      fld('Paced by combat dial', numInput(draft.params, 'paced', onChange, { step: 1, min: 0, max: 1, optional: true }),
        'blank = decided by category (combat/status/card/resource are paced, everything else plays at its authored length); 1 = force on, 0 = force off',
        'narrow'),
    ),
    el('div', { class: 'frow' },
      fld('Companion sound', selectInput(draft, 'sfx',
        [{ value: '', label: '(none)' }].concat(
          ((ctx.vocab && ctx.vocab.sounds) || []).map(s => ({ value: s.id, label: `${s.name} (${s.id})` }))),
        onChange), 'a sound id Vfx.play fires atomically with this visual — the cue pairing lives here, not at call sites'),
    ),
    el('div', { class: 'frow' },
      el('button', { class: 'ghost', text: '▶ Preview', title: 'A rough in-browser sketch — the game’s tween is the authority',
        onclick: e => { e.preventDefault(); playVfxPreview(stage, draft); } }),
    ),
    (stage = el('div', { class: 'vfx-demo-stage' })),
  );
  return box;
}

// The "look" half of a custom-renderer VFX entry. The look is a hand-written renderer in the
// game (CoinFlightFx, KingFallFx, …), registered under this entry's id via Vfx.register_custom —
// so the ONLY thing authorable here is that renderer's own params, and what those are is defined
// by the renderer, not by this editor. Same shape as the filter case for the same reason: an
// open set of keys that no fixed list of fields could keep up with.
//
// This box is also the reason the params survive a save at all. Procedural entries serialize
// through a whitelist (color/scale/duration/intensity), and a custom renderer's numbers are not
// on it — so before this existed, opening a custom entry in the Tool and saving it silently
// stripped every knob its renderer reads, and the effect fell back to its GDScript defaults.
function vfxCustomLook(draft, ctx, onChange) {
  return groupBox('Look (custom renderer)',
    el('div', { class: 'frow' },
      el('div', { class: 'fld wide' }, el('span', { class: 'hint',
        text: `Drawn by the game's registered renderer for "${draft.id || 'this id'}" `
            + '(Vfx.register_custom). The params below are that renderer\'s own dials — their '
            + 'names must match what it reads, and anything it does not read is ignored.' })),
    ),
    el('div', { class: 'frow' },
      fld('Companion sound', selectInput(draft, 'sfx',
        [{ value: '', label: '(none)' }].concat(
          ((ctx.vocab && ctx.vocab.sounds) || []).map(s => ({ value: s.id, label: `${s.name} (${s.id})` }))),
        onChange), 'a sound id Vfx.play fires atomically with this visual'),
    ),
    el('h3', { text: 'Renderer params — every number the look reads' }),
    uniformParamsBox(draft.params, onChange, []),
  );
}

// The "look" half of a filter-backed VFX entry: the look itself lives in the Render Filter, so
// all this owns is WHICH filter, which of its uniforms to override, and how one of them moves.
function vfxFilterLook(draft, ctx, onChange) {
  if (!draft.params.animate) draft.params.animate = {};
  const an = draft.params.animate;
  return groupBox('Look (render filter)',
    el('div', { class: 'frow' },
      fld('Filter', selectInput(draft.params, 'filter',
        [{ value: '', label: '(pick a filter)' }].concat(
          ((ctx.vocab && ctx.vocab.renderFilters) || []).map(f => ({ value: f.id, label: `${f.name} (${f.id})` }))),
        onChange), 'the RenderFilter whose shader draws this effect — authored in the Render Filter tab'),
      el('div', { class: 'fld' }, checkInput(draft, 'sustained', onChange, 'Sustained state (attach/detach) — filters are states, not one-shots')),
    ),
    el('div', { class: 'frow' },
      fld('Companion sound', selectInput(draft, 'sfx',
        [{ value: '', label: '(none)' }].concat(
          ((ctx.vocab && ctx.vocab.sounds) || []).map(s => ({ value: s.id, label: `${s.name} (${s.id})` }))),
        onChange), 'a sound id Vfx.play fires atomically with this visual'),
    ),
    el('h3', { text: 'Uniform overrides — layered over the filter’s own defaults' }),
    uniformParamsBox(draft.params, onChange, ['filter', 'animate']),
    el('h3', { text: 'Animation — breathes one uniform back and forth forever' }),
    el('div', { class: 'frow' },
      fld('Uniform', textInput(an, 'param', onChange, 'e.g. intensity'), 'blank = no animation', 'narrow'),
      fld('From', numInput(an, 'from', onChange, { step: 0.05, float: true, optional: true }), null, 'narrow'),
      fld('To', numInput(an, 'to', onChange, { step: 0.05, float: true, optional: true }), null, 'narrow'),
      fld('Half-period (s)', numInput(an, 'period', onChange, { step: 0.1, float: true, min: 0.05, optional: true }), 'time for one direction', 'narrow'),
    ),
  );
}

const VfxEditor = {
  label: 'VFX',
  newItem: () => ({ id: '', display_name: '', category: 'ui', renderer: 'procedural',
    behavior: 'flash', params: {}, sustained: false, placeholder: true, enabled: true,
    sfx: '', concept: '', explanation: '', prompt: '' }),
  form(draft, ctx, onChange) {
    if (!draft.params) draft.params = {};
    const wrap = el('div');
    // The "look" half swaps wholesale with the renderer: a procedural entry skins a primitive,
    // a filter entry picks a RenderFilter and overrides its uniforms. Rebuilt in place so
    // switching renderer never leaves the other kind's fields (or its params) on screen.
    const lookHost = el('div');
    const renderLook = () => {
      lookHost.textContent = '';
      lookHost.append(draft.renderer === 'filter' ? vfxFilterLook(draft, ctx, onChange)
        : draft.renderer === 'custom' ? vfxCustomLook(draft, ctx, onChange)
        : vfxProceduralLook(draft, ctx, onChange));
    };
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Name', textInput(draft, 'display_name', onChange)),
          fld('Category', selectInput(draft, 'category', VFX_CATEGORIES.map(v => ({ value: v, label: v })), onChange), null, 'narrow'),
          fld('Renderer', selectInput(draft, 'renderer', VFX_RENDERERS.map(v => ({ value: v, label: v })),
            () => { renderLook(); onChange(); }), 'how it renders', 'narrow'),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld' }, checkInput(draft, 'placeholder', onChange, 'Placeholder — no designed look yet (mutable in game via F8)')),
          el('div', { class: 'fld' }, checkInput(draft, 'enabled', onChange,
            'Enabled — unticked = PARKED: no live cue site yet (kept as visible backlog, never deleted)')),
        ),
      ),
      lookHost,
      groupBox('Design',
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Concept — what this moment MEANS (why the effect exists)' }),
            el('textarea', { value: draft.concept || '', oninput: e => { draft.concept = e.target.value; onChange(); } })),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Explanation — what it LOOKS like (the visual design)' }),
            el('textarea', { value: draft.explanation || '', oninput: e => { draft.explanation = e.target.value; onChange(); } })),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'AI generation prompt — for a future asset-backed look (flipbook sprite sheet)' }),
            el('textarea', { value: draft.prompt || '', oninput: e => { draft.prompt = e.target.value; onChange(); } })),
        ),
      ),
    );
    renderLook();
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, display_name: d.display_name || slugToName(d.id),
      category: d.category || 'ui', behavior: d.behavior || 'flash' };
    if (d.renderer && d.renderer !== 'procedural') out.renderer = d.renderer;
    const params = {};
    if (d.renderer === 'custom') {
      // A custom entry's params belong to the GAME's registered renderer for this id, which
      // defines its own dials (CoinFlightFx reads size/duration/stagger/curve/spread). That is an
      // open set, so it passes through verbatim — running it through the procedural whitelist
      // below would delete every one of them on save and silently revert the effect to its
      // GDScript fallbacks.
      for (const [k, v] of Object.entries(d.params || {})) {
        if (v !== '' && v != null) params[k] = v;
      }
    } else if (d.renderer === 'filter') {
      // A filter entry's params are shader uniform names plus the reserved filter/animate keys
      // — an arbitrary set the procedural whitelist below would silently strip. Pass them
      // through verbatim; the filter, not this editor, defines what is meaningful.
      for (const [k, v] of Object.entries(d.params || {})) {
        if (k === 'animate') continue;
        if (v !== '' && v != null) params[k] = v;
      }
      const an = (d.params || {}).animate || {};
      if ((an.param || '').trim()) {
        params.animate = { param: an.param.trim(), from: Number(an.from) || 0,
          to: an.to == null ? 1 : Number(an.to), period: Number(an.period) || 1 };
      }
    } else {
      for (const k of ['color', 'color2', 'shape']) if ((d.params || {})[k]) params[k] = d.params[k];
      for (const k of ['scale', 'duration', 'intensity', 'paced']) if ((d.params || {})[k] != null) params[k] = d.params[k];
    }
    if (Object.keys(params).length) out.params = params;
    if (d.sustained) out.sustained = true;
    if (d.enabled === false) out.enabled = false;   // parked — visible backlog
    if ((d.sfx || '').trim()) out.sfx = d.sfx.trim();
    out.placeholder = d.placeholder !== false;
    out.concept = d.concept || '';
    out.explanation = d.explanation || '';
    out.prompt = d.prompt || '';
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed VFX'} — ${d.category || 'ui'} ${d.sustained ? 'sustained state' : 'one-shot'} riding "${d.behavior}".`];
    // A custom entry's behavior says nothing (the renderer is the look), so its DIALS are what a
    // reader wants at a glance — that is the whole authorable surface of the effect.
    if (d.renderer === 'custom') {
      const dials = Object.entries(d.params || {}).map(([k, v]) => `${k}=${v}`);
      lines.push(dials.length
        ? `Custom renderer, tuned by: ${dials.join(', ')}.`
        : 'Custom renderer with no params — every number is a GDScript default.');
    }
    if (d.enabled === false) lines.push('PARKED (enabled: false) — no live cue site yet; the game skips it at load.');
    lines.push(d.placeholder === false ? 'Designed look — always plays.'
      : 'PLACEHOLDER — plays the procedural sketch; mutable in game with F8 until a look is designed.');
    if (d.sfx) lines.push(`Fires companion sound "${d.sfx}" atomically.`);
    if (d.concept) lines.push(d.concept);
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.params) d.params = {};
    if (!d.renderer) d.renderer = 'procedural';
    if (d.enabled == null) d.enabled = true;
    return d;
  },
  promptFor(d) {
    return d.prompt || `Sprite sheet of a 2d game visual effect, ${d.display_name || slugToName(d.id)}, ${d.explanation || ''}, frames on transparent background`;
  },
  artNote: 'Reference only — the prompt targets a future flipbook/asset renderer; today every entry renders procedurally.',
};

const RenderFilterEditor = {
  label: 'Render Filter',
  newItem: () => ({ id: '', display_name: '', shader: '', pad: 64, layer: 'behind',
    source: 'texture', params: {}, enabled: true, concept: '', explanation: '' }),
  form(draft, ctx, onChange) {
    if (!draft.params) draft.params = {};
    const wrap = el('div');
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Name', textInput(draft, 'display_name', onChange)),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld' }, checkInput(draft, 'enabled', onChange,
            'Enabled — unticked = PARKED: authored but not applied anywhere yet')),
        ),
      ),
      groupBox('Filter',
        el('div', { class: 'frow' },
          fld('Shader', selectInput(draft, 'shader',
            [{ value: '', label: '(pick a shader)' }].concat(
              ((ctx.vocab && ctx.vocab.shaders) || []).map(s => ({ value: s.id, label: `${s.name} — ${s.id}` }))),
            onChange), 'the .gdshader that does the work; it reads the source texture’s alpha'),
        ),
        el('div', { class: 'frow' },
          fld('Pad (px)', numInput(draft, 'pad', onChange, { step: 1, float: true, min: 0 }),
            'spill room — must exceed spread', 'narrow'),
          fld('Layer', selectInput(draft, 'layer', FILTER_LAYERS.map(v => ({ value: v, label: v })), onChange),
            'behind = source occludes the core; overlay = escapes clipping ancestors', 'narrow'),
          fld('Source', selectInput(draft, 'source', FILTER_SOURCES.map(v => ({ value: v, label: v })), onChange),
            'where the silhouette comes from', 'narrow'),
        ),
      ),
      groupBox('Default parameters — keyed BY SHADER UNIFORM NAME, set on the material verbatim',
        uniformParamsBox(draft.params, onChange),
      ),
      groupBox('Design',
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Concept — what this filter is FOR (which moments it exists to serve)' }),
            el('textarea', { value: draft.concept || '', oninput: e => { draft.concept = e.target.value; onChange(); } })),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Explanation — what it looks like and how the shader achieves it' }),
            el('textarea', { value: draft.explanation || '', oninput: e => { draft.explanation = e.target.value; onChange(); } })),
        ),
      ),
    );
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, display_name: d.display_name || slugToName(d.id),
      shader: d.shader || '', pad: typeof d.pad === 'number' ? d.pad : 0,
      layer: d.layer || 'behind', source: d.source || 'texture' };
    const params = {};
    for (const [k, v] of Object.entries(d.params || {})) if (k && v != null) params[k] = v;
    out.params = params;
    if (d.enabled === false) out.enabled = false;   // parked — visible backlog
    out.concept = d.concept || '';
    out.explanation = d.explanation || '';
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed filter'} — a GPU filter derived from the source texture’s own alpha, drawn ${d.layer || 'behind'} it.`];
    if (d.enabled === false) lines.push('PARKED (enabled: false) — the game skips it at load.');
    if (d.shader) lines.push(`Shader: ${d.shader}`);
    lines.push(`Spills up to ${d.pad || 0}px past the source (the padded quad it renders into).`);
    const keys = Object.keys(d.params || {});
    if (keys.length) lines.push(`Sets uniforms: ${keys.join(', ')}.`);
    const spread = (d.params || {}).spread;
    if (typeof spread === 'number' && typeof d.pad === 'number' && spread > d.pad)
      lines.push(`⚠ spread (${spread}) exceeds pad (${d.pad}) — the effect will clip at the quad’s edge.`);
    lines.push('Applied via RenderFilters.apply, or by a VFX entry with renderer "filter" (which adds when it runs and how it animates).');
    if (d.concept) lines.push(d.concept);
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.params) d.params = {};
    if (!d.layer) d.layer = 'behind';
    if (!d.source) d.source = 'texture';
    if (d.pad == null) d.pad = 0;
    if (d.enabled == null) d.enabled = true;
    return d;
  },
  promptFor(d) { return d.explanation || ''; },
  artNote: 'Render filters have no art: the shader IS the look. This panel is unused for this type.',
};

// ═══════════════════════════ NAMED EFFECT ═══════════════════════════════════
// A named effect is a reusable effect PAYLOAD template — the TCG keyword library ("burn" =
// deal 1 damage, a chance to catch Ablaze, each extra stack may burn again). Any effect
// anywhere references one via its "Named effect" select: the call site owns WHEN and ON
// WHOM (trigger/targets), the template supplies WHAT HAPPENS. Retuning a number here
// updates every user; display_name/description are library metadata the game strips.
const NamedEffectEditor = {
  label: 'Named Effect',
  newItem: () => ({ id: '', display_name: '', description: '',
    attribute: 'damage_taken', amount: 1, per_stack: false, riders: [] }),
  form(draft, ctx, onChange) {
    if (!draft.riders) draft.riders = [];
    const wrap = el('div');
    const fx = fxCtx(ctx, 'the target');
    const payloadBox = groupBox('Payload — what happens where this name is used');
    const renderPayload = () => {
      payloadBox.replaceChildren(payloadBox.firstChild);   // keep the group title
      payloadBox.append(el('div', { class: 'frow' },
        fld('Change stat', selectInput(draft, 'attribute', ctx.vocab.effectAttrs
          .map(a => ({ value: a, label: labelOf('attr', a) })), onChange, { optional: true, emptyLabel: '(no stat change)' })),
        fld('By', numInput(draft, 'amount', onChange, { optional: draft.attribute == null, placeholder: '0' }),
          'the keyword’s number — X. Also the stat change where one is set (health: + heals, − damages; damage_taken: positive damage, shield first)', 'narrow'),
        el('div', { class: 'fld' }, checkInput(draft, 'per_stack', onChange,
          'Amount × the holding status’s stacks (off = flat, however tall the pile)')),
      ));
      payloadBox.append(el('div', { class: 'frow' },
        fld('Restrike chance', numInput(draft, 'per_stack_chance', onChange, { float: true, step: 0.05, min: 0, max: 1, optional: true, placeholder: 'off' }),
          'fired from a STACKED status: each stack past the first repeats the effect at this chance (the wildfire’s "each flame may burn again")', 'narrow'),
      ));
      const stWrap = el('div');
      const renderStatus = () => {
        stWrap.replaceChildren();
        if (!draft.status || !draft.status.id) {
          delete draft.status;
          stWrap.append(el('button', { class: 'ghost small list-add', text: '+ also apply a status', onclick: () => {
            draft.status = { id: fx.statusIds()[0] || '', stacks: 1 };
            onChange(); renderStatus();
          } }));
          return;
        }
        stWrap.append(el('div', { class: 'frow' },
          fld('Apply status', statusPicker(draft.status, 'id', fx, onChange)),
          fld('Stacks', numInput(draft.status, 'stacks', onChange, { min: 1, magnitude: true, placeholder: '1 or $X' }),
            'a fixed count, or $X to scale with the keyword’s number ("Blind X")', 'narrow'),
          el('div', { class: 'fld narrow', style: 'justify-content:flex-end' },
            el('button', { class: 'ghost tiny', text: '✕ no status', onclick: () => { delete draft.status; onChange(); renderStatus(); } })),
        ));
      };
      renderStatus();
      payloadBox.append(stWrap);
      payloadBox.append(renderRiderList(el('div'), draft, fx, onChange));
      // The keyword's price for the enemy engine — authored ONCE here, inherited by every
      // call site (and scalable with $X, so "Blind 2" is worth twice "Blind 1").
      payloadBox.append(evalAnnotationSection(draft, onChange, { magnitude: true }));
    };
    renderPayload();
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Library name', textInput(draft, 'display_name', onChange, 'Burn'),
            'shown in pickers — the game never reads it'),
        ),
        el('div', { class: 'frow' },
          fld('Library note', textInput(draft, 'description', onChange, 'what this does, for the picker'),
            'documentation only', 'wide'),
        ),
      ),
      payloadBox,
      el('div', { class: 'hint', text: 'No trigger, no targets: those belong to each call site '
        + '(a status tick, a spell, a spread arrival). This template is only the payload they share. '
        + 'Overriding a field at a call site is possible but exceptional — retune numbers HERE so every user follows.' }),
    );
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, display_name: d.display_name || slugToName(d.id), description: d.description || '' };
    if (d.attribute) { out.attribute = d.attribute; out.amount = d.amount || 0; out.per_stack = !!d.per_stack; }
    // A payload-less amount is still meaningful on a PARAMETERISED template: it is the
    // keyword's default X ("Blind" alone = Blind 1), which every "$X" reads.
    else if (d.amount) out.amount = d.amount;
    if (d.per_stack_chance) out.per_stack_chance = d.per_stack_chance;
    if (d.status && d.status.id) {
      out.status = { id: d.status.id };
      if (d.status.stacks && d.status.stacks !== 1) out.status.stacks = d.status.stacks;
    }
    // The enemy-engine price travels WITH the keyword — dropping it here is how a
    // parameterised template silently loses its pricing on a round-trip through the Tool.
    if (d.eval && Object.keys(d.eval).length) {
      const ev = {};
      for (const [k, v] of Object.entries(d.eval))
        if (v != null && v !== '' && !(k.endsWith('_mul') ? v === 1 : v === 0)) ev[k] = v;
      if (Object.keys(ev).length) out.eval = ev;
    }
    const riders = (d.riders || []).filter(r => r && r.status && r.status.id).map(r => {
      const rr = { status: { id: r.status.id } };
      if (r.chance != null && r.chance !== 1) rr.chance = r.chance;
      if (r.status.stacks && r.status.stacks !== 1) rr.status.stacks = r.status.stacks;
      return rr;
    });
    if (riders.length) out.riders = riders;
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed effect'} — a reusable payload referenced as {"named": "${d.id}"}.`];
    if (d.attribute) lines.push(describeEffect({ trigger: { kind: 'transient' }, targets: { kind: 'self' },
      attribute: d.attribute, amount: d.amount, riders: d.riders, per_stack_chance: d.per_stack_chance }, 'the user'));
    if (d.description) lines.push(d.description);
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.riders) d.riders = [];
    if (d.per_stack == null) d.per_stack = true;   // loader default
    return d;
  },
  promptFor(d) {
    return `Small fantasy spell-effect emblem representing "${d.display_name || slugToName(d.id)}", single centered glowing symbol, painterly style, on a plain solid white background`;
  },
  artNote: 'Named effects have no art slot in the game — generation here is reference-only.',
};

// ═══════════════════════════ INNATE RULE ════════════════════════════════════
// An innate rule is a bundle of effects EVERY unit on the board implicitly carries — the
// rules of the WORLD rather than of any card ("fire scorches the ground it strikes" is one
// rule, not a line copied onto every fire card). There is no holder to speak of and no
// container to select: the effects fire for every unit, and their own trigger conditions
// are the entire gate. A composition condition on the trigger is what narrows a rule to
// "fire units" — and because conditions read the EFFECTIVE composition, a unit merely
// granted fire obeys the rule too.
const InnateEditor = {
  label: 'Innate Rule',
  newItem: () => ({ id: '', display_name: '', description: '', effects: [] }),
  form(draft, ctx, onChange) {
    if (!draft.effects) draft.effects = [];
    const wrap = el('div');
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Rule name', textInput(draft, 'display_name', onChange, 'Fire scorches the ground'),
            'documentation — the game never shows it'),
        ),
        el('div', { class: 'frow' },
          fld('Note', textInput(draft, 'description', onChange, 'what this rule does, and why it is a world rule'),
            'documentation only', 'wide'),
        ),
      ),
      el('div', { class: 'hint', text: 'These effects are carried by EVERY unit on BOTH sides — '
        + 'they are not attached to any card. Their own trigger conditions are the whole gate: '
        + 'to make a rule apply only to fire units, put a composition condition on the trigger '
        + '(a unit that merely COUNTS AS fire obeys it too). Only event-driven effects can be '
        + 'innate — a "while" (standing) effect is refused by the game loader.' }),
      groupBox('Effects every unit carries'),
    );
    renderEffectList(wrap.lastChild, draft.effects, fxCtx(ctx, 'any unit'), onChange);
    return wrap;
  },
  serialize(d) {
    return {
      id: d.id,
      display_name: d.display_name || slugToName(d.id),
      description: d.description || '',
      effects: cleanEffects(d.effects),
    };
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed rule'} — carried by every unit on the board.`];
    for (const e of d.effects || []) lines.push(describeEffect(e, 'any unit'));
    if (d.description) lines.push(d.description);
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.effects) d.effects = [];
    // the pre-directory authoring form spelled the documentation field "note"
    if (d.description == null && d.note != null) { d.description = d.note; delete d.note; }
    return d;
  },
  promptFor(d) {
    return `Small fantasy emblem representing the world rule "${d.display_name || slugToName(d.id)}", single centered glowing symbol, painterly style, on a plain solid white background`;
  },
  artNote: 'Innate rules have no art slot in the game — generation here is reference-only.',
};

const EDITORS = {
  card: CardEditor, relic: RelicEditor, status: StatusEditor, ability: AbilityEditor,
  namedeffect: NamedEffectEditor, innate: InnateEditor,
  charm: CharmEditor, upgrade: UpgradeEditor, encounter: EncounterEditor, nodeweights: NodeWeightsEditor,
  sound: SoundEditor, vfx: VfxEditor, render_filter: RenderFilterEditor, tribe: TribeEditor,
};
