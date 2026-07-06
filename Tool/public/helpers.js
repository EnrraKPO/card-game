/* helpers.js — DOM builders + the designer-facing vocabulary (labels, help text,
 * plain-English effect descriptions). Loaded first. */
'use strict';

// ── tiny DOM builder ─────────────────────────────────────────────────────────
function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  if (attrs) for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k === 'html') node.innerHTML = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (k === 'checked' || k === 'disabled' || k === 'hidden' || k === 'selected') { if (v) node[k] = true; }
    else if (k === 'value') node.value = v;
    else node.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c == null) continue;
    node.append(c.nodeType ? c : document.createTextNode(c));
  }
  return node;
}

// ── field widgets (all call onChange() after mutating the draft) ─────────────
function fld(label, input, hint, extraClass) {
  const f = el('label', { class: 'fld' + (extraClass ? ' ' + extraClass : '') },
    el('span', { class: 'lab', text: label }), input);
  if (hint) f.append(el('span', { class: 'hint', text: hint }));
  return f;
}

function textInput(obj, key, onChange, placeholder) {
  return el('input', {
    type: 'text', value: obj[key] == null ? '' : obj[key], placeholder: placeholder || '',
    oninput: e => { obj[key] = e.target.value; onChange(); },
  });
}

function numInput(obj, key, onChange, opts) {
  opts = opts || {};
  return el('input', {
    type: 'number', value: obj[key] == null ? '' : obj[key],
    step: opts.step || 1, min: opts.min, max: opts.max, placeholder: opts.placeholder || '',
    oninput: e => {
      const v = e.target.value;
      if (v === '') { if (opts.optional) delete obj[key]; else obj[key] = 0; }
      else obj[key] = opts.float ? parseFloat(v) : parseInt(v, 10);
      onChange();
    },
  });
}

function checkInput(obj, key, onChange, labelText) {
  return el('label', { class: 'check' },
    el('input', {
      type: 'checkbox', checked: !!obj[key],
      onchange: e => { obj[key] = e.target.checked; onChange(); },
    }),
    labelText || '');
}

function selectInput(obj, key, options, onChange, opts) {
  // options: [{value, label}] or [value]
  opts = opts || {};
  const sel = el('select', {
    onchange: e => {
      if (e.target.value === '' && opts.optional) delete obj[key];
      else obj[key] = e.target.value;
      onChange();
    },
  });
  if (opts.optional) sel.append(el('option', { value: '', text: opts.emptyLabel || '(none)' }));
  for (const o of options) {
    const v = typeof o === 'string' ? o : o.value;
    const l = typeof o === 'string' ? o : o.label;
    sel.append(el('option', { value: v, text: l, selected: obj[key] === v }));
  }
  return sel;
}

// Toggleable chip set editing an array-of-strings in place.
function chipSet(arr, options, onChange, labelFor) {
  const wrap = el('div', { class: 'chipset' });
  for (const o of options) {
    const chip = el('span', {
      class: 'chip' + (arr.includes(o) ? ' on' : ''),
      text: labelFor ? labelFor(o) : o,
      onclick: () => {
        const i = arr.indexOf(o);
        if (i >= 0) arr.splice(i, 1); else arr.push(o);
        chip.classList.toggle('on');
        onChange();
      },
    });
    wrap.append(chip);
  }
  return wrap;
}

function colorInput(obj, key, onChange) {
  // game colours are bare hex strings ("e0a93b")
  const cur = '#' + (obj[key] || 'aaaaaa').replace(/^#/, '');
  return el('input', {
    type: 'color', value: cur,
    oninput: e => { obj[key] = e.target.value.slice(1); onChange(); },
  });
}

function groupBox(title, ...children) {
  return el('div', { class: 'fgroup' }, el('h3', { text: title }), ...children);
}

// ── designer-facing labels ───────────────────────────────────────────────────
const L = {
  trigger: {
    on_play: 'When played onto the board',
    on_death: 'When it dies',
    on_attack: 'Each time it attacks',
    on_damage_taken: 'Each time it takes damage',
    permanent: 'Once, when it enters the board',
    on_turn_start: 'At the start of each round',
    on_turn_end: 'At the end of each round',
    on_activate: 'When its turn comes up',
  },
  // Native trigger events (the resolver schema): every event has an ORIGIN and dual
  // events also a DESTINATION; conditions gate the participants.
  event: {
    transient: 'On use (spell cast / ability activation)',
    play: 'When a unit is played',
    death: 'When a unit dies',
    attack: 'When a unit attacks (before the hit)',
    struck: 'When a unit is struck (after the hit)',
    activate: 'When a unit takes its turn',
    turn_start: 'At round start (per unit)',
    turn_end: 'At round end (per unit)',
  },
  // Designer nouns for each event's participants (origin, destination).
  eventOrigin: {
    play: 'The played unit', death: 'The dying unit', attack: 'The attacker',
    struck: 'The attacker', activate: 'The acting unit',
    turn_start: 'The unit whose round it is', turn_end: 'The unit whose round it is',
  },
  eventDestination: { attack: 'The unit being struck', struck: 'The struck unit' },
  relation: {
    self: 'this card itself',
    ally: 'an ally of this card (itself included)',
    enemy: 'an enemy of this card',
  },
  // Native targeting kinds (the TargetResolver schema).
  targetKind: {
    all: 'Every unit matching the conditions',
    auto: 'Auto-pick from matching units',
    manual: 'A unit the player picks',
    manual_slot: 'A slot the player picks (may be empty)',
    participant: 'An event participant / itself',
  },
  criterion: { nearest: 'nearest to this card', random: 'at random' },
  participant: {
    holder: 'this card itself',
    origin: 'the event ORIGIN (whoever caused it)',
    destination: 'the event DESTINATION (whoever received it)',
  },
  policy: {
    self: 'Itself',
    single_nearest: 'The nearest enemy',
    single_random: 'A random enemy',
    all_enemies: 'Every enemy',
    all_allies: 'Every ally (incl. itself)',
    all: 'Every unit on the board',
    manual: 'A unit the player picks',
    manual_slot: 'A slot the player picks (may be empty)',
    attack_target: 'The unit it is striking',
    attacker: 'The unit that dealt the blow',
    subject: 'The unit the event is about',
  },
  subject: {
    self: 'its own action only',
    ally: 'any ALLY’s action',
    enemy: 'any ENEMY’s action',
    any: 'anyone’s action',
  },
  attr: {
    health: 'Health (heal + / damage −, ignores shield)',
    damage_taken: 'Damage (hits shield first)',
    attack: 'Attack',
    speed: 'Speed',
    shield: 'Shield',
    cost: 'Mana cost',
  },
  condAttr: {
    health: 'Health', attack: 'Attack', speed: 'Speed', cost: 'Mana cost',
    piece_count: 'How many chess pieces it holds',
    element_count: 'How many elements it holds',
  },
  cmp: { gt: 'more than', gte: 'at least', lt: 'less than', lte: 'at most', eq: 'exactly', neq: 'anything but' },
  modKey: {
    'unit.attack': 'Unit Attack (your units)',
    'unit.health': 'Unit max Health (your units)',
    'unit.speed': 'Unit Speed (your units)',
    'card.cost': 'Card mana cost (your cards)',
    'mana.initial': 'Starting mana (turn 1)',
    'mana.max': 'Maximum mana (ramp ceiling)',
    'mana.per_turn': 'Bonus mana every turn (stacks above the cap)',
    'hand.size.initial': 'Opening hand size',
    'draw.per_turn': 'Cards drawn per round',
    'gold.initial': 'Starting gold',
    'king.max_health': 'King bonus max Health',
    'relic.capacity': 'Relic slots',
    'reward.essence': 'Bonus essence per combat win',
    'reward.king_piece_chance': 'Chance an Elite drops a King Piece (0–1)',
  },
  hook: {
    rallying_cry: 'Rallying Cry — other allies gain +1 Attack when the subject attacks',
    deliver_material: 'Deliver Material — merges/spawns the ability’s material into the picked slot',
  },
  decay: {
    duration: 'Timer — counts down each round',
    stacks: 'Stacks — count IS the timer (StS poison)',
    none: 'Never — lasts the whole fight',
    intercept: 'Charges — one spent per blocked/rewritten hit',
  },
  stacking: {
    refresh: 'Refresh — reset the timer, no stacking',
    extend: 'Extend — add durations together',
    stack: 'Stack — +1 stack, effects scale with count',
    independent: 'Independent — separate instances',
  },
  element: { fire: 'Fire', water: 'Water', air: 'Air', earth: 'Earth', darkness: 'Darkness', light: 'Light' },
  piece: { pawn: 'Pawn', knight: 'Knight', bishop: 'Bishop', rook: 'Rook', queen: 'Queen', king: 'King' },
};

function labelOf(dict, key) { return (L[dict] && L[dict][key]) || key; }

// ── plain-English descriptions ───────────────────────────────────────────────
function describeCondition(c) {
  if (!c) return '';
  if (c.relation) return 'is ' + labelOf('relation', c.relation);
  if (c.status) return (c.present === false ? 'not carrying ' : 'carrying ') + c.status;
  if (c.composition) {
    const list = Array.isArray(c.composition) ? c.composition : [c.composition];
    return (c.present === false ? 'made of none of: ' : 'made of any of: ') + list.join(', ');
  }
  return `${labelOf('condAttr', c.attribute)} ${labelOf('cmp', c.comparator)} ${c.value}`;
}

function signed(n) { return (n > 0 ? '+' : '') + n; }

function describeEffect(e, ownerNoun) {
  const owner = ownerNoun || 'this';
  if (!e) return '';
  const kind = e.kind || (e.key ? 'modifier' : e.intercept ? 'interceptor' : e.custom ? 'custom' : 'triggered');
  if (kind === 'modifier') {
    let s = `Passive: ${labelOf('modKey', e.key)} ${signed(e.amount || 0)}`;
    if (e.filter && e.filter.kind) s += ` (only ${e.filter.kind}s)`;
    if (e.filter && e.filter.has_element) s += ' (element cards only)';
    if (e.conditions && e.conditions.length)
      s += ` — only for cards ${e.conditions.map(describeCondition).join(' and ')}`;
    return s + '.';
  }
  if (kind === 'interceptor') {
    const side = e.role === 'target' ? 'incoming' : 'outgoing';
    const chan = e.channel ? `${e.channel} ` : '';
    let verb;
    if (e.op === 'mul') verb = e.amount === 0 ? 'is fully blocked' : `is multiplied ×${e.amount}`;
    else verb = `is shifted by ${signed(e.amount || 0)}`;
    let s = `The holder’s ${side} ${chan}${e.intercept || 'damage'} ${verb}`;
    if (e.chance != null && e.chance !== 1) s += ` (${Math.round(e.chance * 100)}% of the time)`;
    return s + '.';
  }
  // triggered / custom
  let when, subj = '';
  if (e.trigger && typeof e.trigger === 'object') {
    // native resolver form: event + participant condition lists
    const t = e.trigger;
    if (t.kind === 'transient') {
      when = labelOf('event', 'transient');
    } else {
      when = labelOf('event', t.event);
      const gates = [];
      const oc = t.kind === 'dual_event' ? t.origin_conditions : t.conditions;
      if (oc && oc.length)
        gates.push(`origin ${oc.map(describeCondition).join(' and ')}`);
      if (t.kind === 'dual_event' && t.destination_conditions && t.destination_conditions.length)
        gates.push(`destination ${t.destination_conditions.map(describeCondition).join(' and ')}`);
      if (gates.length) subj = ' — where ' + gates.join('; ');
    }
  } else {
    when = labelOf('trigger', e.trigger || 'on_play');
    if (e.subject && e.subject !== 'self') subj = ` — reacting to ${labelOf('subject', e.subject)}`;
    if (e.subject_elements && e.subject_elements.length) subj += ` (subject must be ${e.subject_elements.join('/')})`;
  }
  let who;
  if (e.targets && typeof e.targets === 'object') {
    const tg = e.targets;
    const conds = (tg.conditions || []).map(describeCondition).join(' and ');
    if (tg.kind === 'participant') who = labelOf('participant', tg.participant || 'holder');
    else if (tg.kind === 'auto') who = `${tg.count > 1 ? tg.count + ' units' : 'one unit'} ${labelOf('criterion', tg.criterion || 'nearest')}`;
    else if (tg.kind === 'manual') who = 'a unit the player picks';
    else if (tg.kind === 'manual_slot') who = 'a slot the player picks';
    else who = 'every unit';
    if (conds && tg.kind !== 'participant') who += ` (${conds})`;
    else if (conds) who += ` (if ${conds})`;
  } else {
    who = labelOf('policy', e.targeting_policy || 'self');
  }
  const parts = [];
  if (kind === 'custom') {
    parts.push(labelOf('hook', e.custom));
  } else {
    if (e.attribute) {
      const amt = e.amount || 0;
      if (e.attribute === 'health') parts.push(amt >= 0 ? `heal ${amt} Health` : `deal ${-amt} direct damage`);
      else if (e.attribute === 'damage_taken') parts.push(`deal ${amt} damage (shield first)`);
      else parts.push(`${signed(amt)} ${labelOf('attr', e.attribute).split(' (')[0]}`);
    }
    if (e.status && e.status.id) {
      let st = `apply ${e.status.stacks || 1}× ${e.status.id}`;
      if (e.status.duration != null && e.status.duration !== -9999) st += ` for ${e.status.duration} rounds`;
      parts.push(st);
    }
  }
  if (!parts.length) parts.push('(no payload yet)');
  let s = `${when}${subj} → ${who}: ${parts.join(' and ')}`;
  if (e.conditions && e.conditions.length && !(e.targets && typeof e.targets === 'object'))
    s += ` — only if ${e.conditions.map(describeCondition).join(' and ')}`;
  if (e.chance != null && e.chance !== 1) s += ` (${Math.round(e.chance * 100)}% chance)`;
  return s + '.';
}

function describeCost(cost) {
  if (!cost) return 'free, taps the holder';
  const bits = [];
  if (cost.mana) bits.push(`${cost.mana} mana`);
  bits.push(cost.tap === false ? 'does NOT tap the holder' : 'taps the holder for the round');
  return bits.join(', ');
}

// escape for use in prompts etc.
function slugToName(id) {
  return (id || '').split('_').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
}
