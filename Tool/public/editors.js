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

// ═════════════════════════════════ CARD ═════════════════════════════════════
const CardEditor = {
  label: 'Card',
  newItem: () => ({
    id: '', display_name: '', description: '', art_instructions: '',
    cost: 1, attack: 2, health: 3, speed: 3, shield: 0,
    elements: [], chess_pieces: [], effects: [], abilities: [],
    ranged: false, is_king: false, enemy_only: false,
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
          fld('Name', textInput(draft, 'display_name', onChange, 'shown on the card')),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Tooltip / flavour text' }),
            el('textarea', { value: draft.description || '', oninput: e => { draft.description = e.target.value; onChange(); } })),
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
        ),
        el('div', { class: 'frow' },
          fld('Plays as', selectInput(draft, 'card_type', [
            { value: 'unit', label: 'Unit (fielded on the board)' },
            { value: 'spell', label: 'Spell (cast, never fielded)' },
          ], onChange, { optional: true, emptyLabel: 'auto — elements-only = spell, otherwise unit' })),
        ),
      ),
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
          fld('Name', textInput(draft, 'display_name', onChange)),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Description (shown in shop / relic tray)' }),
            el('textarea', { value: draft.description || '', oninput: e => { draft.description = e.target.value; onChange(); } })),
        ),
        el('div', { class: 'frow' },
          fld('Chip colour', colorInput(draft, 'color', onChange), 'fallback chip when there is no icon', 'narrow'),
          fld('Chip glyph', textInput(draft, 'letter', onChange, '✦'), 'one letter/symbol', 'narrow'),
          fld('Shop price (gold)', numInput(draft, 'price', onChange, { min: 0 }), null, 'narrow'),
        ),
      ),
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

// ═════════════════════════════════ STATUS ═══════════════════════════════════
const StatusEditor = {
  label: 'Status',
  newItem: () => ({ id: '', display_name: '', description: '', beneficial: false, aura: false,
    color: '8fd0ff', glyph: '✦', default_duration: 2, decay: 'duration', decay_phase: 'turn_end',
    stacking: 'refresh', max_stacks: 9, effects: [], abilities: [] }),
  form(draft, ctx, onChange) {
    for (const k of ['effects', 'abilities']) if (!draft[k]) draft[k] = [];
    const wrap = el('div');
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Name', textInput(draft, 'display_name', onChange)),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Tooltip description' }),
            el('textarea', { value: draft.description || '', oninput: e => { draft.description = e.target.value; onChange(); } })),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld' }, checkInput(draft, 'beneficial', onChange, 'Beneficial (buff tint; unchecked = debuff)')),
          el('div', { class: 'fld' }, checkInput(draft, 'aura', onChange, 'Aura frame — draw a persistent frame over the card')),
          fld('Pip colour', colorInput(draft, 'color', onChange), null, 'narrow'),
          fld('Pip glyph', textInput(draft, 'glyph', onChange, '☠'), 'short symbol', 'narrow'),
        ),
      ),
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
    out.effects = cleanEffects(d.effects);
    if (d.abilities && d.abilities.length) out.abilities = d.abilities.slice();
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed status'} — ${d.beneficial ? 'buff' : 'debuff'}.`];
    lines.push(`Wears off: ${labelOf('decay', d.decay || 'duration')}; re-apply: ${labelOf('stacking', d.stacking || 'refresh')}.`);
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
          fld('Name', textInput(draft, 'display_name', onChange)),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Tooltip description' }),
            el('textarea', { value: draft.description || '', oninput: e => { draft.description = e.target.value; onChange(); } })),
        ),
      ),
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
          fld('Name', textInput(draft, 'display_name', onChange)),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Description' }),
            el('textarea', { value: draft.description || '', oninput: e => { draft.description = e.target.value; onChange(); } })),
        ),
        el('div', { class: 'frow' },
          fld('Pip colour', colorInput(draft, 'color', onChange), null, 'narrow'),
          fld('Pip glyph', textInput(draft, 'letter', onChange, '✦'), null, 'narrow'),
          fld('Attaches to', selectInput(draft, 'targets', [
            { value: 'unit', label: 'units only (combat charms)' },
            { value: 'spell', label: 'spells only' },
            { value: 'any', label: 'any card' },
          ], onChange), 'the King is never eligible'),
        ),
      ),
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
        fld('Name', textInput(draft, 'display_name', onChange)),
        fld('Accent colour', colorInput(draft, 'color', onChange), null, 'narrow'),
      ),
      el('div', { class: 'frow' },
        el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Description' }),
          el('textarea', { value: draft.description || '', oninput: e => { draft.description = e.target.value; onChange(); } })),
      ),
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
            fld('Name', textInput(n, 'display_name', onChange)),
            fld('Icon glyph', textInput(n, 'icon', onChange, '✦'), null, 'narrow'),
          ),
          el('div', { class: 'frow' },
            el('div', { class: 'fld wide' }, el('span', { class: 'lab', text: 'Description' }),
              el('textarea', { value: n.description || '', oninput: e => { n.description = e.target.value; onChange(); } })),
          ),
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

// ═══════════════════════════════ ENCOUNTER ══════════════════════════════════
const EncounterEditor = {
  label: 'Encounter',
  newItem: () => ({ id: '', node_type: 'combat', min_floor: 0, max_floor: 999, weight: 1,
    enemy_king: '', power_bonus: 0, enemy_pool: [], pick_count: [14, 20],
    gold_reward: [20, 40], exp_reward: 1, relic_reward: 0, ai: 'default', reward_pool: 'default' }),
  form(draft, ctx, onChange) {
    if (!draft.enemy_pool) draft.enemy_pool = [];
    if (!Array.isArray(draft.pick_count)) draft.pick_count = [14, 20];
    if (!Array.isArray(draft.gold_reward)) draft.gold_reward = [0, 0];
    const wrap = el('div');
    const kings = cardIdOptions(ctx, c => c.is_king);
    const pcObj = { min: draft.pick_count[0], max: draft.pick_count[1] };
    const grObj = { min: draft.gold_reward[0], max: draft.gold_reward[1] };
    const syncPc = () => { draft.pick_count = [pcObj.min, pcObj.max]; };
    const syncGr = () => { draft.gold_reward = [grObj.min, grObj.max]; };

    wrap.append(
      groupBox('Template',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Serves node type', selectInput(draft, 'node_type', [
            { value: 'combat', label: 'Combat' }, { value: 'elite', label: 'Elite' }, { value: 'boss', label: 'Boss' },
          ], onChange)),
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
      ),
      groupBox('Enemy side',
        el('div', { class: 'frow' },
          fld('Enemy King / Captain', kings.length
            ? selectInput(draft, 'enemy_king', kings, onChange, { optional: true, emptyLabel: 'generic crown King (default)' })
            : textInput(draft, 'enemy_king', onChange, 'card id'),
            'do NOT also list it in the pool'),
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
          fld('Experience', numInput(draft, 'exp_reward', onChange, { min: 0 }), 'profile XP toward upgrade points', 'narrow'),
          fld('Relic drop chance', numInput(draft, 'relic_reward', onChange, { float: true, step: 0.1, min: 0, max: 1 }), '0–1', 'narrow'),
          fld('AI', textInput(draft, 'ai', onChange, 'default'), null, 'narrow'),
          fld('Reward pool', textInput(draft, 'reward_pool', onChange, 'default'), null, 'narrow'),
        ),
      ),
    );

    const poolBox = groupBox('Enemy card pool (weighted, sampled with replacement)');
    wrap.append(poolBox);
    const cardOpts = cardIdOptions(ctx, c => !c.is_king);
    const renderPool = () => {
      while (poolBox.children.length > 1) poolBox.lastChild.remove();
      const table = el('table', { class: 'mini' },
        el('tr', null, el('th', { text: 'Card' }), el('th', { text: 'Weight' }), el('th')));
      draft.enemy_pool.forEach((p, i) => {
        table.append(el('tr', null,
          el('td', null, selectInput(p, 'id', cardOpts, onChange)),
          el('td', { style: 'width:90px' }, numInput(p, 'weight', onChange, { float: true, step: 0.5, min: 0 })),
          el('td', { style: 'width:40px' }, el('button', { class: 'ghost tiny', text: '✕', onclick: () => {
            draft.enemy_pool.splice(i, 1); onChange(); renderPool();
          } })),
        ));
      });
      poolBox.append(table, el('button', { class: 'ghost small list-add', text: '+ add card', onclick: () => {
        draft.enemy_pool.push({ id: (cardOpts[0] && cardOpts[0].value) || '', weight: 1 });
        onChange(); renderPool();
      } }));
    };
    renderPool();
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, node_type: d.node_type, min_floor: d.min_floor || 0, max_floor: d.max_floor == null ? 999 : d.max_floor,
      weight: d.weight == null ? 1 : d.weight };
    if (d.min_stage != null && d.min_stage !== 1) out.min_stage = d.min_stage;
    if (d.max_stage != null && d.max_stage !== 999) out.max_stage = d.max_stage;
    if (d.enemy_king) out.enemy_king = d.enemy_king;
    if (d.power_bonus) out.power_bonus = d.power_bonus;
    out.enemy_pool = (d.enemy_pool || []).map(p => ({ id: p.id, weight: p.weight == null ? 1 : p.weight }));
    out.pick_count = d.pick_count.slice(0, 2);
    if (d.gold_reward && (d.gold_reward[0] || d.gold_reward[1])) out.gold_reward = d.gold_reward.slice(0, 2);
    if (d.exp_reward != null) out.exp_reward = d.exp_reward;
    if (d.ai && d.ai !== 'default') out.ai = d.ai; else out.ai = 'default';
    out.reward_pool = d.reward_pool || 'default';
    if (d.relic_reward) out.relic_reward = d.relic_reward;
    return out;
  },
  summarize(d) {
    const lines = [`${d.id || 'Unnamed'} — a ${d.node_type} fight on floors ${d.min_floor || 0}–${d.max_floor == null ? 999 : d.max_floor}.`];
    lines.push(`Enemy King: ${d.enemy_king || 'generic crown King'}${d.power_bonus ? `, power +${d.power_bonus}` : ''}.`);
    lines.push(`Deck: ${d.pick_count[0]}–${d.pick_count[1]} cards from ${(d.enemy_pool || []).length} pool entries.`);
    const g = d.gold_reward || [0, 0];
    lines.push(`Win: ${g[0]}–${g[1]} gold, ${d.exp_reward || 0} XP${d.relic_reward ? `, ${Math.round(d.relic_reward * 100)}% relic drop` : ''}.`);
    return lines;
  },
  toDraft(g) {
    const d = JSON.parse(JSON.stringify(g));
    if (!d.enemy_pool) d.enemy_pool = [];
    if (!Array.isArray(d.pick_count)) d.pick_count = [1, 1];
    if (!Array.isArray(d.gold_reward)) d.gold_reward = [0, 0];
    if (d.weight == null) d.weight = 1;
    if (d.exp_reward == null) d.exp_reward = 1;
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

const SoundEditor = {
  label: 'Sound',
  newItem: () => ({ id: '', display_name: '', category: 'ui', concept: '', prompt: '',
    file: '', volume_db: 0, loop: false }),
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
      groupBox('Playback',
        el('div', { class: 'frow' },
          fld('Asset file', textInput(draft, 'file', onChange, '(empty = placeholder synth)'),
            'bare filename inside assets/sound/ — .mp3/.ogg/.wav'),
          fld('Volume trim (dB)', numInput(draft, 'volume_db', onChange, { step: 1, float: true, min: -60, max: 12 }),
            '0 = as authored, negative = gentler', 'narrow'),
          el('div', { class: 'fld' }, checkInput(draft, 'loop', onChange, 'Looped bed (drone / ambience / music)')),
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
    if ((d.file || '').trim()) out.file = d.file.trim();
    if (d.volume_db) out.volume_db = d.volume_db;
    if (d.loop) out.loop = true;
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed sound'} — ${d.category || 'ui'} ${d.loop ? 'loop' : 'one-shot'}.`];
    lines.push(d.file ? `Plays assets/sound/${d.file}${d.volume_db ? ` at ${d.volume_db} dB` : ''}.`
      : 'No asset yet — the game plays a placeholder synth blip for this event.');
    if (d.concept) lines.push(d.concept);
    return lines;
  },
  toDraft(g) { return JSON.parse(JSON.stringify(g)); },
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
  'float_label', 'burst', 'travel', 'reticle', 'dissolve'];
const VFX_SUSTAINED = ['glow', 'pulse', 'sparkle'];

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
    case 'dissolve':
      anim(overlay({ inset: '18%', background: color, opacity: 0 }),
        [{ opacity: 0 }, { opacity: 0.75 }, { opacity: 0 }], dur || 500);
      break;
  }
}

const VfxEditor = {
  label: 'VFX',
  newItem: () => ({ id: '', display_name: '', category: 'ui', renderer: 'procedural',
    behavior: 'flash', params: {}, sustained: false, placeholder: true,
    sfx: '', concept: '', explanation: '', prompt: '' }),
  form(draft, ctx, onChange) {
    if (!draft.params) draft.params = {};
    const wrap = el('div');
    let stage;
    wrap.append(
      groupBox('Identity',
        el('div', { class: 'frow' },
          idField(draft, onChange, ctx.isNew),
          fld('Name', textInput(draft, 'display_name', onChange)),
          fld('Category', selectInput(draft, 'category', VFX_CATEGORIES.map(v => ({ value: v, label: v })), onChange), null, 'narrow'),
        ),
        el('div', { class: 'frow' },
          el('div', { class: 'fld' }, checkInput(draft, 'placeholder', onChange, 'Placeholder — no designed look yet (mutable in game via F8)')),
        ),
      ),
      groupBox('Look (procedural renderer)',
        el('div', { class: 'frow' },
          fld('Behavior', selectInput(draft, 'behavior', VFX_BEHAVIORS.map(v => ({ value: v, label: v })), onChange), 'the primitive this effect rides', 'narrow'),
          el('div', { class: 'fld' }, checkInput(draft, 'sustained', onChange, `Sustained state (attach/detach; needs ${VFX_SUSTAINED.join('/')})`)),
        ),
        el('div', { class: 'frow' },
          fld('Colour', colorInput(draft.params, 'color', onChange), null, 'narrow'),
          fld('Scale', numInput(draft.params, 'scale', onChange, { step: 0.1, float: true, min: 0.2, max: 4, optional: true }), 'size/intensity multiplier', 'narrow'),
          fld('Duration (s)', numInput(draft.params, 'duration', onChange, { step: 0.05, float: true, min: 0.05, max: 5, optional: true }), 'blank = behavior default', 'narrow'),
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
      ),
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
    return wrap;
  },
  serialize(d) {
    const out = { id: d.id, display_name: d.display_name || slugToName(d.id),
      category: d.category || 'ui', behavior: d.behavior || 'flash' };
    if (d.renderer && d.renderer !== 'procedural') out.renderer = d.renderer;
    const params = {};
    for (const k of ['color', 'color2']) if ((d.params || {})[k]) params[k] = d.params[k];
    for (const k of ['scale', 'duration', 'intensity']) if ((d.params || {})[k] != null) params[k] = d.params[k];
    if (Object.keys(params).length) out.params = params;
    if (d.sustained) out.sustained = true;
    if ((d.sfx || '').trim()) out.sfx = d.sfx.trim();
    out.placeholder = d.placeholder !== false;
    out.concept = d.concept || '';
    out.explanation = d.explanation || '';
    out.prompt = d.prompt || '';
    return out;
  },
  summarize(d) {
    const lines = [`${d.display_name || d.id || 'Unnamed VFX'} — ${d.category || 'ui'} ${d.sustained ? 'sustained state' : 'one-shot'} riding "${d.behavior}".`];
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
    return d;
  },
  promptFor(d) {
    return d.prompt || `Sprite sheet of a 2d game visual effect, ${d.display_name || slugToName(d.id)}, ${d.explanation || ''}, frames on transparent background`;
  },
  artNote: 'Reference only — the prompt targets a future flipbook/asset renderer; today every entry renders procedurally.',
};

const EDITORS = {
  card: CardEditor, relic: RelicEditor, status: StatusEditor, ability: AbilityEditor,
  charm: CharmEditor, upgrade: UpgradeEditor, encounter: EncounterEditor, nodeweights: NodeWeightsEditor,
  sound: SoundEditor, vfx: VfxEditor,
};
