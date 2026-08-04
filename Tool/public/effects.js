/* effects.js — the shared effect & condition builder.
 * Effects are edited directly in their deployed JSON shape (the same dicts
 * Effect.from_dict parses in the game), so what you see in the preview is
 * exactly what ships. */
'use strict';

const EFFECT_KINDS = [
  { value: 'triggered', label: 'Triggered — reacts to an event (when)' },
  { value: 'standing', label: 'Standing — stat change while active (while)' },
  { value: 'modifier', label: 'Modifier — run-wide number change' },
  { value: 'interceptor', label: 'Interceptor — rewrites a pending change before it lands' },
  { value: 'custom', label: 'Custom — a named code hook' },
];

function isStanding(e) {
  return e.trigger && typeof e.trigger === 'object' && e.trigger.kind === 'while';
}

function effectKindOf(e) {
  if (isStanding(e)) return 'standing';
  return e.kind || (e.key != null ? 'modifier' : e.intercept != null ? 'interceptor' : e.custom != null ? 'custom' : 'triggered');
}

// Run-scope containers (relic/upgrade) have no holder unit — the identity relation
// ("self") is inexpressible there; the editor hides it (stage-2 affordance).
function isRunScopeCtx(ctx) {
  return ctx && (ctx.ownerNoun === 'this relic' || ctx.ownerNoun === 'this upgrade');
}

// Rebuild an effect object as a given kind, keeping what carries over.
function coerceEffectKind(e, kind, ctx) {
  for (const k of Object.keys(e)) delete e[k];
  if (kind === 'modifier') Object.assign(e, { kind: 'modifier', key: 'unit.attack', amount: 1 });
  else if (kind === 'standing') Object.assign(e, { trigger: { kind: 'while' },
    targets: { kind: 'self' }, tracker: { kind: 'container' }, attribute: 'attack', amount: 1 });
  else if (kind === 'interceptor') Object.assign(e, { kind: 'interceptor', intercept: 'damage', channel: 'attack',
    of: { participant: 'target', relation: isRunScopeCtx(ctx) ? 'ally' : 'self' }, op: 'mul', amount: 0 });
  else if (kind === 'custom') Object.assign(e, { kind: 'custom', custom: 'rallying_cry',
    trigger: { kind: 'dual_event', event: 'attack', origin_of: 'self', origin_conditions: [], destination_conditions: [] },
    targets: { kind: 'self', conditions: [] } });
  else Object.assign(e, { trigger: { kind: 'event', event: 'play', of: 'self', conditions: [] },
    targets: { kind: 'self', conditions: [] },
    attribute: 'health', amount: -1 });
}

// Context-aware blank effect: a status most often wants a standing per-stack buff on its
// carrier; everything else starts as the classic on-play triggered effect.
function defaultEffect(ctx) {
  if (ctx && ctx.ownerNoun === 'the carrier')
    return { trigger: { kind: 'while' }, targets: { kind: 'self' },
      tracker: { kind: 'stacks' }, attribute: 'attack', amount: 1 };
  return { trigger: { kind: 'event', event: 'play', of: 'self', conditions: [] },
    targets: { kind: 'self', conditions: [] },
    attribute: 'attack', amount: 1 };
}

// ── trigger normalization: the builder edits the NATIVE resolver form ────────────────
// Legacy content (trigger string + subject + subject_elements) converts on first render,
// exactly the way the game parses it (see TriggerResolver.from_legacy).
const LEGACY_TRIGGER_EVENTS = {
  on_play: ['play', false], on_death: ['death', false], on_attack: ['attack', true],
  on_damage_taken: ['struck', true],
  on_turn_start: ['turn_start', false], on_turn_end: ['turn_end', false], on_activate: ['activate', false],
};

// Native lists authored before the owner model spelled identity as a {relation: "self"}
// CONDITION; the game now extracts it into structure. Do the same on edit: consume any
// identity entry, report whether one was there, and convert ally/enemy onto allegiance.
function extractIdentity(list) {
  let found = false;
  const out = [];
  for (const c of list || []) {
    if (c && c.relation === 'self') { found = true; continue; }
    if (c && (c.relation === 'ally' || c.relation === 'enemy')) { out.push({ allegiance: c.relation }); continue; }
    out.push(c);
  }
  return { found, out };
}

function normalizeTrigger(e) {
  if (e.trigger && typeof e.trigger === 'object') {
    const t = e.trigger;
    if (t.kind === 'event') {
      const r = extractIdentity(t.conditions);
      if (r.found) t.of = 'self';
      t.conditions = r.out;
    } else if (t.kind === 'dual_event') {
      const ro = extractIdentity(t.origin_conditions);
      const rd = extractIdentity(t.destination_conditions);
      if (ro.found) t.origin_of = 'self';
      if (rd.found) t.destination_of = 'self';
      t.origin_conditions = ro.out;
      t.destination_conditions = rd.out;
    }
    return;
  }
  if (e.trigger === 'permanent') {   // the legacy "permanent" trigger IS the standing kind
    e.trigger = { kind: 'while' };
    delete e.subject;
    delete e.subject_elements;
    return;
  }
  const [event, isDual] = LEGACY_TRIGGER_EVENTS[e.trigger || 'on_play'] || ['play', false];
  // Legacy subject: "self" is the structural participant gate; ally/enemy are allegiance.
  const gateSelf = e.subject !== 'any' && e.subject !== 'ally' && e.subject !== 'enemy';
  const conds = [];
  if (e.subject === 'ally' || e.subject === 'enemy') conds.push({ allegiance: e.subject });
  if (e.subject_elements && e.subject_elements.length) conds.push({ composition: e.subject_elements.slice() });
  if (isDual) {
    // the legacy subject was the attacker for on_attack, the struck unit for on_damage_taken
    e.trigger = e.trigger === 'on_damage_taken'
      ? { kind: 'dual_event', event, ...(gateSelf ? { destination_of: 'self' } : {}), origin_conditions: [], destination_conditions: conds }
      : { kind: 'dual_event', event, ...(gateSelf ? { origin_of: 'self' } : {}), origin_conditions: conds, destination_conditions: [] };
  } else {
    e.trigger = { kind: 'event', event, ...(gateSelf ? { of: 'self' } : {}), conditions: conds };
  }
  delete e.subject;
  delete e.subject_elements;
}

// Legacy targeting_policy + top-level conditions → the native "targets" object, exactly
// the way the game maps it (TargetResolver.from_legacy — implicit scopes become relation
// conditions; `subject` follows the normalized trigger's event).
function normalizeTargets(e) {
  if (e.targets && typeof e.targets === 'object') {
    if (e.targets.kind === 'side') { delete e.targets.conditions; delete e.conditions; delete e.targeting_policy; return; }
    // pre-owner-model native data: identity conditions collapse into the self kind
    const r = extractIdentity(e.targets.conditions);
    e.targets.conditions = r.out;
    if (r.found && (e.targets.kind === 'all' || e.targets.kind == null)) e.targets.kind = 'self';
    if (e.targets.kind === 'participant' && (e.targets.participant || 'holder') === 'holder') {
      e.targets.kind = 'self';   // canonical spelling
      delete e.targets.participant;
    }
    delete e.conditions; delete e.targeting_policy; return;
  }
  const conds = (e.conditions || []).slice();
  const p = e.targeting_policy || 'self';
  const subjectIsDestination = e.trigger && typeof e.trigger === 'object' && e.trigger.event === 'struck';
  const map = {
    self: { kind: 'self', conditions: conds },
    single_nearest: { kind: 'auto', criterion: 'nearest', conditions: [{ allegiance: 'enemy' }, ...conds] },
    single_random: { kind: 'auto', criterion: 'random', conditions: [{ allegiance: 'enemy' }, ...conds] },
    all_enemies: { kind: 'all', conditions: [{ allegiance: 'enemy' }, ...conds] },
    all_allies: { kind: 'all', conditions: [{ allegiance: 'ally' }, ...conds] },
    all: { kind: 'all', conditions: conds },
    manual: { kind: 'manual', conditions: conds },
    manual_slot: { kind: 'manual_slot', conditions: conds },
    attack_target: { kind: 'participant', participant: 'destination', conditions: conds },
    attacker: { kind: 'participant', participant: 'origin', conditions: conds },
    subject: { kind: 'participant', participant: subjectIsDestination ? 'destination' : 'origin', conditions: conds },
  };
  e.targets = map[p] || map.all;
  delete e.conditions;
  delete e.targeting_policy;
}

// Rebuild the targets object for a newly picked kind, carrying the conditions over.
function retargetTargets(e, kindKey) {
  const conds = (e.targets && e.targets.conditions) || [];
  if (kindKey === 'auto') e.targets = { kind: 'auto', criterion: 'nearest', count: 1, conditions: conds };
  else if (kindKey === 'participant') e.targets = { kind: 'participant', participant: 'origin', conditions: conds };
  else if (kindKey === 'side') e.targets = { kind: 'side', of: 'own' };   // no conditions: players have no predicates
  else e.targets = { kind: kindKey, conditions: conds };
}

// Rebuild the trigger object for a newly picked event, carrying the primary condition list over.
function retargetTrigger(e, eventKey) {
  const t = e.trigger;
  const primary = (t.kind === 'dual_event' ? t.origin_conditions : t.conditions) || [];
  if (eventKey === 'transient') e.trigger = { kind: 'transient' };
  else if (eventKey === 'attack' || eventKey === 'struck' || eventKey === 'kill')
    e.trigger = { kind: 'dual_event', event: eventKey, origin_conditions: primary, destination_conditions: [] };
  else e.trigger = { kind: 'event', event: eventKey, conditions: primary };
}

// ── condition editor ─────────────────────────────────────────────────────────
const COND_KINDS = [
  { value: 'attribute', label: 'Stat check' },
  { value: 'status', label: 'Has / lacks a status' },
  { value: 'composition', label: 'Made of / not made of' },
  { value: 'allegiance', label: 'Side — ally or enemy of this effect' },
];
// Interceptors only: a predicate over the PENDING change itself (its amount) rather than
// a unit — how "heals only" is spelled on a health intercept (amount > 0).
const MUTATION_COND_KIND = { value: 'mutation', label: 'Pending amount check (interceptor)' };

function condKindOf(c) {
  return (c.allegiance != null || c.relation != null) ? 'allegiance'
    : c.status != null ? 'status'
    : c.composition != null ? 'composition'
    : c.mutation != null ? 'mutation' : 'attribute';
}

// Conditions are PREDICATES only. Identity ("the holder itself") is never one — it is
// picked structurally (the "self" target kind / the trigger's "Whose action" gate).
// Allegiance compares the tested unit's SIDE against the effect's OWNER, which every
// container has (a relic's owner is the player) — so it works even with no holder unit.
function allegianceOptions() {
  return [
    { value: 'ally', label: 'on this effect’s own side (ally — holder included)' },
    { value: 'enemy', label: 'on the opposite side (enemy)' },
  ];
}

// Edits whichever key the condition carries: native data says "allegiance", legacy data
// "relation" (the game maps it losslessly; the editor converges on allegiance on rebuild).
function relationValueKey(c) {
  return c.relation != null ? 'relation' : 'allegiance';
}

function renderCondition(c, ctx, onChange, onRemove, allowMutation) {
  const card = el('div', { class: 'cond-card' });
  const kind = condKindOf(c);
  const rebuild = () => { onChange(); renderInto(); };

  function renderInto() {
    card.replaceChildren();
    const kindSel = el('select', {
      onchange: e => {
        for (const k of Object.keys(c)) delete c[k];
        if (e.target.value === 'status') Object.assign(c, { status: (ctx.statusIds()[0] || 'poison'), present: true });
        else if (e.target.value === 'composition') Object.assign(c, { composition: ['king'], present: false });
        else if (e.target.value === 'allegiance') Object.assign(c, { allegiance: 'ally' });
        else if (e.target.value === 'mutation') Object.assign(c, { mutation: 'amount', comparator: 'gt', value: 0 });
        else Object.assign(c, { attribute: 'health', comparator: 'lte', value: 3 });
        onChange(); renderInto();
      },
    });
    const kindOpts = allowMutation ? COND_KINDS.concat([MUTATION_COND_KIND]) : COND_KINDS;
    for (const o of kindOpts) kindSel.append(el('option', { value: o.value, text: o.label, selected: condKindOf(c) === o.value }));

    const row = el('div', { class: 'frow' });
    row.append(fld('Condition type', kindSel));
    const k = condKindOf(c);
    if (k === 'allegiance') {
      row.append(
        fld('Must be', selectInput(c, relationValueKey(c), allegianceOptions(), onChange)),
      );
    } else if (k === 'status') {
      row.append(
        fld('Presence', boolSelect(c, 'present', 'must HAVE the status', 'must NOT have it', onChange)),
        fld('Status', statusPicker(c, 'status', ctx, onChange)),
      );
    } else if (k === 'composition') {
      if (!Array.isArray(c.composition)) c.composition = c.composition ? [c.composition] : [];
      // TWO QUESTIONS, TWO LENSES (see EffectCondition.composition_counted):
      //  • presence — "is it fire?" — reads the TREATED-AS lens, so a blessing's granted
      //    component satisfies it.
      //  • count — "is it built from two fire?" — reads the card's REAL composition. A
      //    blessing says a unit is to be treated as fire, never how MUCH fire it is, so it
      //    contributes nothing to a quantity. This is how fire_fire-only rules are authored.
      const mode = { m: c.count != null ? 'count' : 'presence' };
      row.append(
        fld('Asks', selectInput(mode, 'm', [
          { value: 'presence', label: 'is it made of… (counts blessings)' },
          { value: 'count', label: 'how many is it built from… (real composition only)' },
        ], () => {
          if (mode.m === 'count') { delete c.present; c.count = 2; c.comparator = 'gte'; }
          else { delete c.count; delete c.comparator; delete c.value; c.present = true; }
          onChange(); renderInto();
        }), 'a granted (blessed) component answers "is it fire?" but never "how much fire?"'),
      );
      if (mode.m === 'count') {
        row.append(
          fld('Count is', selectInput(c, 'comparator', ctx.vocab.comparators.map(x => ({ value: x, label: labelOf('cmp', x) })), onChange)),
          fld('N', numInput(c, 'count', onChange, { min: 0 }), null, 'narrow'),
        );
      } else {
        row.append(fld('Presence', boolSelect(c, 'present', 'must contain any of…', 'must contain NONE of…', onChange)));
      }
      row.append(
        el('div', { class: 'fld wide' },
          el('span', { class: 'lab', text: mode.m === 'count' ? 'Counted from (occurrences are summed)' : 'Elements / pieces' }),
          chipSet(c.composition, ctx.vocab.elements.concat(ctx.vocab.pieces), onChange,
            id => labelOf('element', id) !== id ? labelOf('element', id) : labelOf('piece', id))),
      );
    } else if (k === 'mutation') {
      row.append(
        fld('The pending amount is', selectInput(c, 'comparator', ctx.vocab.comparators.map(x => ({ value: x, label: labelOf('cmp', x) })), onChange),
          'e.g. gt 0 on a health intercept = heals only'),
        fld('Value', numInput(c, 'value', onChange), null, 'narrow'),
      );
    } else {
      row.append(
        fld('Stat', selectInput(c, 'attribute', ctx.vocab.condAttrs.map(a => ({ value: a, label: labelOf('condAttr', a) })), onChange)),
        fld('Is', selectInput(c, 'comparator', ctx.vocab.comparators.map(x => ({ value: x, label: labelOf('cmp', x) })), onChange)),
        fld('Value', numInput(c, 'value', onChange), null, 'narrow'),
      );
    }
    row.append(el('div', { class: 'fld narrow', style: 'justify-content:flex-end' },
      el('button', { class: 'ghost tiny', text: '✕ remove', onclick: onRemove })));
    card.append(row);
  }
  renderInto();
  return card;
}

function boolSelect(obj, key, trueLabel, falseLabel, onChange) {
  const sel = el('select', {
    onchange: e => { obj[key] = e.target.value === 'yes'; onChange(); },
  });
  sel.append(el('option', { value: 'yes', text: trueLabel, selected: obj[key] !== false }));
  sel.append(el('option', { value: 'no', text: falseLabel, selected: obj[key] === false }));
  return sel;
}

// ── damage riders ("the damage carries a follow-on") ─────────────────────────
// One roll PER DAMAGE INSTANCE, flat — the amount never multiplies the rolls. Shared by
// the effect builder and the named-effect editor (both edit the same authored shape).
function renderRiderList(host, e, ctx, onChange) {
  const render = () => {
    host.replaceChildren();
    (e.riders || []).forEach((r, i) => {
      if (!r.status) r.status = { id: ctx.statusIds()[0] || '', stacks: 1 };
      host.append(el('div', { class: 'frow' },
        fld('The damage may apply', statusPicker(r.status, 'id', ctx, onChange),
          'rolled once per damage instance that actually lands'),
        fld('Stacks', numInput(r.status, 'stacks', onChange, { min: 1 }), null, 'narrow'),
        fld('Chance', numInput(r, 'chance', onChange, { float: true, step: 0.05, min: 0, max: 1, optional: true, placeholder: '1.0' }),
          '0–1; empty = always', 'narrow'),
        el('div', { class: 'fld narrow', style: 'justify-content:flex-end' },
          el('button', { class: 'ghost tiny', text: '✕ remove', onclick: () => {
            e.riders.splice(i, 1);
            if (!e.riders.length) delete e.riders;
            onChange(); render();
          } })),
      ));
    });
    host.append(el('button', { class: 'ghost small list-add', text: '+ the damage carries a rider (e.g. burn may ignite)', onclick: () => {
      if (!e.riders) e.riders = [];
      e.riders.push({ chance: 1.0, status: { id: ctx.statusIds()[0] || '', stacks: 1 } });
      onChange(); render();
    } }));
  };
  render();
  return host;
}

function statusPicker(obj, key, ctx, onChange) {
  const ids = ctx.statusIds();
  if (ids.length === 0) return textInput(obj, key, onChange, 'status id');
  if (obj[key] && !ids.includes(obj[key])) ids.unshift(obj[key]);
  return selectInput(obj, key, ids, onChange);
}

// ── effect editor ────────────────────────────────────────────────────────────
// ctx: { vocab, statusIds(), ownerNoun }
// Shared "conditions" section — targeting on EVERY effect kind is gated by the same list.
function conditionSection(e, ctx, localChange, labelWhenSome, allowMutation) {
  if (!e.conditions) e.conditions = [];
  const condWrap = el('div');
  const renderConds = () => {
    condWrap.replaceChildren();
    condWrap.append(el('span', { class: 'lab subtle', text: e.conditions.length ? labelWhenSome : '' }));
    e.conditions.forEach((c, i) => {
      condWrap.append(renderCondition(c, ctx, localChange, () => {
        e.conditions.splice(i, 1); localChange(); renderConds();
      }, allowMutation));
    });
    condWrap.append(el('button', { class: 'ghost small list-add', text: '+ add target condition', onclick: () => {
      e.conditions.push({ attribute: 'health', comparator: 'lte', value: 3 });
      localChange(); renderConds();
    } }));
  };
  renderConds();
  return condWrap;
}

// The participant-gate select ("of" / "origin_of" / "destination_of"): identity with the
// holder is a structural yes/no, never a condition. Absent key = anyone.
function ofSelect(t, key, ctx, onChange) {
  const holder = { v: t[key] === 'self' ? 'self' : 'any' };
  const sel = el('select', {
    onchange: e => {
      if (e.target.value === 'self') t[key] = 'self';
      else delete t[key];
      onChange();
    },
  });
  const noun = ctx.ownerNoun || 'the holder';
  sel.append(el('option', { value: 'any', text: 'anyone', selected: holder.v === 'any' }));
  sel.append(el('option', { value: 'self', text: `${noun} itself only`, selected: holder.v === 'self' }));
  return sel;
}

function originHint(event) {
  const noun = labelOf('eventOrigin', event);
  return noun && noun !== event ? ` (${noun.toLowerCase()})` : '';
}

function destinationHint(event) {
  const noun = labelOf('eventDestination', event);
  return noun && noun !== event ? ` (${noun.toLowerCase()})` : '';
}

// A trigger participant's condition list (always labeled — it names WHO is being gated).
// New conditions default to the relation form, the most common activation gate.
function participantConditionSection(obj, key, ctx, localChange, labelText) {
  if (!obj[key]) obj[key] = [];
  const wrap = el('div');
  const render = () => {
    wrap.replaceChildren();
    wrap.append(el('span', { class: 'lab subtle', text: labelText + (obj[key].length ? '' : ' (anything — add a condition to narrow)') }));
    obj[key].forEach((c, i) => {
      wrap.append(renderCondition(c, ctx, localChange, () => {
        obj[key].splice(i, 1); localChange(); render();
      }));
    });
    wrap.append(el('button', { class: 'ghost small list-add', text: '+ add condition', onclick: () => {
      obj[key].push({ allegiance: 'ally' });
      localChange(); render();
    } }));
  };
  render();
  return wrap;
}

function renderEffect(e, ctx, onChange, onRemove) {
  const card = el('div', { class: 'fx-card' });

  function renderInto() {
    card.replaceChildren();
    const kind = effectKindOf(e);
    const sumEl = el('div', { class: 'fx-sum', text: describeEffect(e, ctx.ownerNoun) });
    const localChange = () => { onChange(); sumEl.textContent = describeEffect(e, ctx.ownerNoun); };

    const kindSel = el('select', {
      onchange: ev => { coerceEffectKind(e, ev.target.value, ctx); onChange(); renderInto(); },
    });
    for (const o of EFFECT_KINDS) kindSel.append(el('option', { value: o.value, text: o.label, selected: kind === o.value }));

    card.append(el('div', { class: 'fx-head' }, kindSel, sumEl,
      el('button', { class: 'ghost tiny', text: '✕', title: 'Remove effect', onclick: onRemove })));

    const body = el('div', { class: 'fx-body' });
    card.append(body);

    if (kind === 'standing') {
      // A STANDING effect: live while its tracker is. Two payloads: a stat fold (read-time
      // attribute delta) or a composition GRANT (the target COUNTS AS containing components
      // for condition resolution — see the game's LiveEffects.effective_composition).
      normalizeTargets(e);
      if (!e.tracker) e.tracker = { kind: 'container' };
      const tgHolder = { kind: e.targets.kind };
      const payload = { mode: Array.isArray(e.grants) ? 'grants' : 'stat' };
      const payloadFlds = payload.mode === 'grants' ? [] : [
        fld('Stat', selectInput(e, 'attribute', ['attack', 'health', 'speed', 'cost']
          .map(a => ({ value: a, label: labelOf('standingAttr', a) })), localChange),
          'health here means MAX health — standing effects never write current health'),
        fld('By', numInput(e, 'amount', localChange, { float: true, step: 'any' }), 'per tracker intensity (× stacks)', 'narrow'),
      ];
      body.append(el('div', { class: 'frow' },
        fld('Payload', selectInput(payload, 'mode', [
          { value: 'stat', label: 'changes a stat' },
          { value: 'grants', label: 'grants components (counts as…)' },
        ], () => {
          if (payload.mode === 'grants') { delete e.attribute; delete e.amount; e.grants = []; }
          else { delete e.grants; e.attribute = 'attack'; e.amount = 1; }
          onChange(); renderInto();
        })),
        ...payloadFlds,
        fld('Applies to', selectInput(tgHolder, 'kind', [
          { value: 'self', label: `${ctx.ownerNoun || 'the holder'} itself` },
          { value: 'all', label: 'every unit matching the conditions' },
        ], () => { retargetTargets(e, tgHolder.kind); onChange(); renderInto(); })),
        fld('Lives as long as', selectInput(e.tracker, 'kind', (ctx.vocab.trackerKinds || ['container', 'stacks'])
          .map(k => ({ value: k, label: labelOf('trackerKind', k) })), localChange)),
      ));
      if (payload.mode === 'grants')
        body.append(el('div', { class: 'frow' },
          el('div', { class: 'fld wide' },
            el('span', { class: 'lab', text: 'Counts as (elements / pieces)' }),
            chipSet(e.grants, ctx.vocab.elements.concat(ctx.vocab.pieces), localChange,
              id => labelOf('element', id) !== id ? labelOf('element', id) : labelOf('piece', id)),
            el('span', { class: 'hint', text: 'the target counts as containing these for every condition while active — its real composition never changes; composition conditions on a grant must be positive (grants only ever ADD)' })),
        ));
      if (e.targets.kind !== 'self')
        body.append(participantConditionSection(e.targets, 'conditions', ctx, localChange, 'TARGETS must satisfy:'));
    } else if (kind === 'modifier') {
      const row = el('div', { class: 'frow' },
        fld('What number', selectInput(e, 'key', ctx.vocab.modifierKeys.map(k => ({ value: k, label: labelOf('modKey', k) })), localChange),
          'unit.* / card.cost fold into matching cards; the rest are run-wide numbers'),
        fld('Change by', numInput(e, 'amount', localChange, { float: true, step: 'any' }), 'negative lowers it', 'narrow'),
      );
      body.append(row);
      if (!e.filter) e.filter = {};
      const isCard = ['unit.attack','unit.health','unit.speed','card.cost'].includes(e.key);
      if (isCard) {
        body.append(el('div', { class: 'frow' },
          fld('Only card kind', selectInput(e.filter, 'kind', [
            { value: 'unit', label: 'units only' }, { value: 'spell', label: 'spells only' },
          ], localChange, { optional: true, emptyLabel: 'any card' })),
          el('div', { class: 'fld' }, el('span', { class: 'lab', text: 'Element gate' }),
            checkInput(e.filter, 'has_element', localChange, 'only cards that carry an element')),
        ));
        // Every card the modifier folds into is a TARGET — gate it with the shared conditions
        // (e.g. "+1 Health" + composition [pawn] = "+1 Health to pawn units").
        body.append(conditionSection(e, ctx, localChange, 'Only fold into cards where ALL of these hold:'));
      }
      cleanupFilter(e);
    } else if (kind === 'interceptor') {
      // Legacy role → the native relational gate on first render, exactly the way the
      // game parses it (role = participant + identity — see Effect._parse_intercept_gate).
      if (!e.of || typeof e.of !== 'object') {
        e.of = { participant: e.role === 'source' ? 'source' : 'target', relation: 'self' };
        delete e.role;
      }
      const relationOpts = [
        ...(isRunScopeCtx(ctx) ? [] : [{ value: 'self', label: `${ctx.ownerNoun || 'the holder'} itself` }]),
        { value: 'ally', label: 'on this effect’s own side (ally)' },
        { value: 'enemy', label: 'on the opposite side (enemy)' },
        { value: 'any', label: 'anyone' },
      ];
      body.append(el('div', { class: 'frow' },
        fld('Rewrites', selectInput(e, 'intercept', [
          { value: 'damage', label: 'damage (shield-first hits)' },
          { value: 'health', label: 'health (direct heals / wounds)' },
          { value: 'status', label: 'status stacks being applied' },
        ], localChange), 'the pending change being rewritten'),
        fld('Only from', selectInput(e, 'channel', [
          { value: 'attack', label: 'unit strikes (auto-attacks)' },
        ], localChange, { optional: true, emptyLabel: 'any source (spells, poison, strikes…)' })),
      ));
      body.append(el('div', { class: 'frow' },
        fld('Scrutinises', selectInput(e.of, 'participant', [
          { value: 'target', label: 'the one receiving it (armor / barrier)' },
          { value: 'source', label: 'the one causing it (blind)' },
        ], localChange), 'which side of the pending change is matched'),
        fld('Who must be', selectInput(e.of, 'relation', relationOpts, localChange),
          'relative to this effect’s owner'),
      ));
      body.append(el('div', { class: 'frow' },
        fld('Operation', selectInput(e, 'op', [
          { value: 'mul', label: 'multiply the amount' }, { value: 'add', label: 'shift the amount' },
        ], localChange), 'multiply ×0 = full block; shift −3 = armor that shaves 3'),
        fld('Amount', numInput(e, 'amount', localChange, { float: true, step: 'any' }), null, 'narrow'),
        fld('Chance', numInput(e, 'chance', localChange, { float: true, step: 0.05, min: 0, max: 1, optional: true, placeholder: '1.0' }),
          'roll per hit, 0–1; empty = always', 'narrow'),
      ));
      body.append(conditionSection(e, ctx, localChange,
        'Only when ALL of these hold (unit checks read the scrutinised participant):', true));
    } else {
      // triggered / custom share the event plumbing
      const rows = [];
      if (kind === 'custom') {
        rows.push(el('div', { class: 'frow' },
          fld('Code hook', selectInput(e, 'custom', ctx.vocab.customHooks.map(h => ({ value: h, label: labelOf('hook', h) })), localChange),
            'a hand-written behaviour registered in EffectHooks'),
        ));
      }
      // ── activation: one event, gated by conditions on its participants ──
      normalizeTrigger(e);
      normalizeTargets(e);
      const t = e.trigger;
      const tg = e.targets;
      const eventKey = t.kind === 'transient' ? 'transient' : t.event;
      const eventOpts = ['transient', ...ctx.vocab.simpleEvents, ...ctx.vocab.dualEvents]
        .map(v => ({ value: v, label: labelOf('event', v) }));
      const evHolder = { ev: eventKey };
      const tgHolder = { kind: tg.kind };
      rows.push(el('div', { class: 'frow' },
        fld('When', selectInput(evHolder, 'ev', eventOpts, () => {
          retargetTrigger(e, evHolder.ev); onChange(); renderInto();
        })),
        fld('Affects', selectInput(tgHolder, 'kind', (ctx.vocab.targetKinds || ['all', 'auto', 'manual', 'manual_slot', 'participant'])
          .map(k => ({ value: k, label: labelOf('targetKind', k) })), () => {
          retargetTargets(e, tgHolder.kind); onChange(); renderInto();
        })),
        fld('Chance', numInput(e, 'chance', localChange, { float: true, step: 0.05, min: 0, max: 1, optional: true, placeholder: '1.0' }),
          '0–1; empty = always fires', 'narrow'),
      ));
      // per-kind targeting sub-fields
      if (tg.kind === 'auto') {
        rows.push(el('div', { class: 'frow' },
          fld('Pick', selectInput(tg, 'criterion', (ctx.vocab.criteria || ['nearest', 'random'])
            .map(c => ({ value: c, label: labelOf('criterion', c) })), localChange)),
          fld('How many', numInput(tg, 'count', localChange, { min: 1 }), null, 'narrow'),
        ));
      } else if (tg.kind === 'participant') {
        rows.push(el('div', { class: 'frow' },
          // "holder" is spelled as the self target kind now — not offered here.
          fld('Which participant', selectInput(tg, 'participant', (ctx.vocab.participants || ['origin', 'destination'])
            .filter(p => p !== 'holder')
            .map(p => ({ value: p, label: labelOf('participant', p) })), localChange),
            'origin/destination need an event — nothing is targeted on plain use'),
        ));
      } else if (tg.kind === 'side') {
        rows.push(el('div', { class: 'frow' },
          fld('Which player', selectInput(tg, 'of', (ctx.vocab.sideSelectors || ['own', 'opponent'])
            .map(s => ({ value: s, label: s === 'own' ? 'Own side (the holder’s player)' : 'The opponent' })), localChange),
            'a PLAYER, not a unit — pair with a side stat (draw/discard/mana/max mana)'),
        ));
      }
      // The two slots are the ABSTRACT participants — same for every event. The event-specific
      // noun is only a parenthetical hint, so the UI teaches the model instead of hiding it.
      // Each watched slot carries the structural IDENTITY gate ("Whose action" — the
      // participant must BE the holder) separately from its predicate conditions.
      if (t.kind === 'event') {
        rows.push(el('div', { class: 'frow' },
          fld('Whose event', ofSelect(t, 'of', ctx, localChange),
            'identity is structural — conditions below are predicates on the origin'),
        ));
        rows.push(participantConditionSection(t, 'conditions', ctx, localChange,
          'ORIGIN' + originHint(t.event) + ' must satisfy:'));
      } else if (t.kind === 'dual_event') {
        if (!t.origin_conditions) t.origin_conditions = [];
        if (!t.destination_conditions) t.destination_conditions = [];
        rows.push(el('div', { class: 'frow' },
          fld('Origin is', ofSelect(t, 'origin_of', ctx, localChange)),
          fld('Destination is', ofSelect(t, 'destination_of', ctx, localChange)),
        ));
        // The kill event alone carries a CAUSE gate — match only kills by a given cause
        // ("poison" = a status id, or the kind "attack"/"effect"). Empty = any cause.
        if (t.event === 'kill') {
          const causeChange = () => { if (!t.cause) delete t.cause; localChange(); };
          rows.push(el('div', { class: 'frow' },
            fld('Killed by', textInput(t, 'cause', causeChange, 'any cause (e.g. poison, attack)'),
              'match only this cause — a status id like "poison", or a kind ("attack")'),
          ));
        }
        rows.push(participantConditionSection(t, 'origin_conditions', ctx, localChange,
          'ORIGIN' + originHint(t.event) + ' must satisfy:'));
        rows.push(participantConditionSection(t, 'destination_conditions', ctx, localChange,
          'DESTINATION' + destinationHint(t.event) + ' must satisfy:'));
      }

      if (kind !== 'custom') {
        // A side target commits side stats and nothing else (no unit stats, no status —
        // mirrors the game's load validation), so the payload vocabulary follows the kind.
        const sideTargeted = tg.kind === 'side';
        // ── NAMED-EFFECT reference: the library template supplies the payload ──
        // The call site keeps trigger/targets; picking a name replaces the hand-authored
        // payload fields below wholesale (the game merges the template at parse time).
        const namedPool = (ctx.vocab.namedEffects || []);
        if (!sideTargeted && namedPool.length) {
          rows.push(el('div', { class: 'frow' },
            fld('Named effect', selectInput(e, 'named', namedPool.map(n => ({ value: n.id, label: n.name || n.id })), () => {
              if (e.named) { delete e.attribute; delete e.amount; delete e.status; delete e.riders; delete e.per_stack_chance; }
              else { delete e.named; e.attribute = 'attack'; e.amount = 1; }
              onChange(); renderInto();
            }, { optional: true, emptyLabel: '(none — author the payload below)' }),
              'a library payload (🧩 Named Effects tab) — what happens comes from the template, when/whom stays here'),
          ));
        }
        if (e.named) {
          body.append(...rows);
          if (tg.kind !== 'side')
            body.append(participantConditionSection(tg, 'conditions', ctx, localChange, 'TARGETS must satisfy:'));
          return;
        }
        const attrPool = sideTargeted ? (ctx.vocab.sideAttrs || ['draw', 'discard', 'mana', 'max_mana'])
          : ctx.vocab.effectAttrs;
        if (sideTargeted && !attrPool.includes(e.attribute)) { e.attribute = attrPool[0]; delete e.status; }
        rows.push(el('div', { class: 'frow' },
          fld('Change stat', selectInput(e, 'attribute', attrPool.map(a => ({ value: a, label: labelOf('attr', a) })), localChange, sideTargeted ? {} : { optional: true, emptyLabel: '(no stat change)' })),
          fld('By', numInput(e, 'amount', localChange, { optional: e.attribute == null, placeholder: '0' }),
            sideTargeted ? 'mana: + gains (uncapped above max), − drains.' : 'health: + heals, − damages. damage_taken: positive number of damage.', 'narrow'),
        ));
        // Damage riders + the restrike chance — the wildfire vocabulary, valid on any
        // damage payload (riders ride the damage; restrike needs a stacked container).
        if (e.attribute === 'damage_taken' && !sideTargeted) {
          rows.push(renderRiderList(el('div'), e, ctx, localChange));
          rows.push(el('div', { class: 'frow' },
            fld('Restrike chance', numInput(e, 'per_stack_chance', localChange, { float: true, step: 0.05, min: 0, max: 1, optional: true, placeholder: 'off' }),
              'stacked container only: each stack past the first repeats this effect at this chance (0–1; empty = the first activation is all)', 'narrow'),
          ));
        }
        // status payload
        const hasStatus = !sideTargeted && !!(e.status && e.status.id != null);
        const stWrap = el('div');
        const renderStatus = () => {
          stWrap.replaceChildren();
          if (!e.status) {
            stWrap.append(el('button', { class: 'ghost small list-add', text: '+ also apply a status', onclick: () => {
              e.status = { id: ctx.statusIds()[0] || '', stacks: 1 };
              localChange(); renderStatus();
            } }));
            return;
          }
          stWrap.append(el('div', { class: 'frow' },
            fld('Apply status', statusPicker(e.status, 'id', ctx, localChange)),
            fld('Stacks', numInput(e.status, 'stacks', localChange, { min: 1 }), null, 'narrow'),
            fld('Duration', numInput(e.status, 'duration', localChange, { optional: true, placeholder: 'default' }),
              'empty = the status’s own default', 'narrow'),
            // WHICH LAYER receives it (mirrors Effect.status_layer): the resolved unit, or
            // the board SLOT beneath it. "Burn the ground you strike" is destination + ground.
            fld('Lands on', selectInput(e.status, 'layer', [
              { value: 'units', label: 'the unit (default)' },
              { value: 'ground', label: 'the ground beneath it' },
            ], localChange), 'ground = the board slot at the target’s cell, not the unit', 'narrow'),
            el('div', { class: 'fld narrow', style: 'justify-content:flex-end' },
              el('button', { class: 'ghost tiny', text: '✕ no status', onclick: () => { delete e.status; localChange(); renderStatus(); } })),
          ));
        };
        if (!sideTargeted) {
          renderStatus();
          rows.push(stWrap);
        }
      }

      if (tg.kind !== 'side')
        rows.push(participantConditionSection(tg, 'conditions', ctx, localChange, 'TARGETS must satisfy:'));
      body.append(...rows);
    }
  }
  renderInto();
  return card;
}

function cleanupFilter(e) {
  if (e.filter && !e.filter.kind && !e.filter.has_element) delete e.filter;
  if (e.filter && e.filter.has_element === false) delete e.filter.has_element;
  if (e.filter && !Object.keys(e.filter).length) delete e.filter;
}

// The whole list, with an "add" button.
function renderEffectList(container, effects, ctx, onChange) {
  const nl = { text: '' };   // survives re-renders — typed text isn't lost on list edits
  function renderInto() {
    container.replaceChildren();
    effects.forEach((e, i) => {
      container.append(renderEffect(e, ctx, onChange, () => {
        effects.splice(i, 1); onChange(); renderInto();
      }));
    });
    container.append(el('button', { class: 'ghost small list-add', text: '+ add effect', onclick: () => {
      effects.push(defaultEffect(ctx)); onChange(); renderInto();
    } }));
    // ✨ from words — the LLM translates a plain-English description into effect rows.
    // Generated effects land HERE as ordinary editable rows, never straight in the file;
    // the server validates (retrying on errors) and the save gate still has final say.
    const inp = textInput(nl, 'text', () => {},
      '…or describe it in words — e.g. “+1 strength to all pawn units”');
    inp.addEventListener('keydown', ev => { if (ev.key === 'Enter') { ev.preventDefault(); btn.click(); } });
    const btn = el('button', { class: 'ghost small', text: '✨ from words',
      title: 'Ask the local LLM (Ollama, effects model in Settings) to write these effects — check the plain-words restatement after',
      onclick: async () => {
        const text = (nl.text || '').trim();
        if (!text) { inp.focus(); return; }
        btn.disabled = true; btn.textContent = '✨ thinking…';
        try {
          const out = await api('/api/effects/from-text', { type: ctx.type, text });
          if (!(out.effects || []).length) {
            toast('The LLM produced no effects — try rephrasing.', 'err');
          } else {
            for (const e of out.effects) effects.push(e);
            if (out.warning) toast('Check the new effect — the validator still objects: ' + out.warning, 'err');
            else toast(`${out.effects.length} effect(s) added — verify the plain-words line says what you meant.`, 'ok');
            nl.text = '';
            onChange();
          }
        } catch (err) {
          toast('Effect generation failed: ' + err.message, 'err');
        }
        renderInto();
      } });
    inp.style.flex = '1';
    btn.style.flexShrink = '0';
    container.append(el('div', { style: 'display:flex; align-items:center; gap:6px; margin-top:6px' }, inp, btn));
  }
  renderInto();
}

// Strip transient/empty fields so the deployed JSON stays clean.
function cleanEffectForDeploy(e) {
  const out = JSON.parse(JSON.stringify(e));
  if (out.trigger && typeof out.trigger === 'object') {
    // native resolver form: prune empty participant lists and "anyone" gates; the legacy
    // subject keys never coexist with it (normalizeTrigger folded them in)
    for (const k of ['conditions', 'origin_conditions', 'destination_conditions'])
      if (out.trigger[k] && !out.trigger[k].length) delete out.trigger[k];
    for (const k of ['of', 'origin_of', 'destination_of'])
      if (out.trigger[k] != null && out.trigger[k] !== 'self') delete out.trigger[k];
    delete out.subject;
    delete out.subject_elements;
  }
  if (out.tracker && String(out.tracker.kind || 'container') === 'container')
    delete out.tracker;   // the container-existence default — absent means exactly that
  if (out.targets && typeof out.targets === 'object') {
    if (out.targets.conditions && !out.targets.conditions.length) delete out.targets.conditions;
    if (out.targets.count === 1) delete out.targets.count;
    delete out.conditions;          // native form owns the conditions
    delete out.targeting_policy;    // superseded by the targets object
  }
  if (out.conditions && !out.conditions.length) delete out.conditions;
  if (out.subject_elements && !out.subject_elements.length) delete out.subject_elements;
  if (out.chance === 1 || out.chance == null) delete out.chance;
  if (out.status) {
    if (out.status.duration == null) delete out.status.duration;
    if (out.status.stacks === 1) delete out.status.stacks;
    // "units" is the loader default — the data files leave it unspelled (byte-faithful)
    if (!out.status.layer || out.status.layer === 'units') delete out.status.layer;
    if (!out.status.id) delete out.status;
  }
  if (out.attribute == null || out.attribute === '') { delete out.attribute; if (out.status || out.custom || out.named) delete out.amount; }
  if (out.filter && !Object.keys(out.filter).length) delete out.filter;
  // Named-effect reference + the wildfire payload extras: prune empties/defaults.
  if (out.named == null || out.named === '') delete out.named;
  if (Array.isArray(out.riders)) {
    out.riders = out.riders.filter(r => r && r.status && r.status.id);
    for (const r of out.riders) {
      if (r.chance == null || r.chance === 1) delete r.chance;
      if (r.status.stacks === 1) delete r.status.stacks;
      if (r.status.duration == null) delete r.status.duration;
    }
    if (!out.riders.length) delete out.riders;
  }
  if (!out.per_stack_chance) delete out.per_stack_chance;
  const kind = effectKindOf(out);
  // "kind" is inferred by the game parser for modifier (key) / custom / interceptor,
  // and triggered is the default — keep explicit kind only where the data files do.
  if (kind === 'triggered') delete out.kind;
  return out;
}
