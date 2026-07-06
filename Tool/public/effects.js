/* effects.js — the shared effect & condition builder.
 * Effects are edited directly in their deployed JSON shape (the same dicts
 * Effect.from_dict parses in the game), so what you see in the preview is
 * exactly what ships. */
'use strict';

const EFFECT_KINDS = [
  { value: 'triggered', label: 'Triggered — reacts to an event' },
  { value: 'modifier', label: 'Modifier — passive number change' },
  { value: 'interceptor', label: 'Interceptor — rewrites damage before it lands' },
  { value: 'custom', label: 'Custom — a named code hook' },
];

function effectKindOf(e) {
  return e.kind || (e.key != null ? 'modifier' : e.intercept != null ? 'interceptor' : e.custom != null ? 'custom' : 'triggered');
}

// Rebuild an effect object as a given kind, keeping what carries over.
function coerceEffectKind(e, kind) {
  for (const k of Object.keys(e)) delete e[k];
  if (kind === 'modifier') Object.assign(e, { kind: 'modifier', key: 'unit.attack', amount: 1 });
  else if (kind === 'interceptor') Object.assign(e, { kind: 'interceptor', intercept: 'damage', channel: 'attack', role: 'target', op: 'mul', amount: 0 });
  else if (kind === 'custom') Object.assign(e, { kind: 'custom', custom: 'rallying_cry',
    trigger: { kind: 'dual_event', event: 'attack', origin_conditions: [{ relation: 'self' }], destination_conditions: [] },
    targets: { kind: 'participant', participant: 'holder', conditions: [] } });
  else Object.assign(e, { trigger: { kind: 'event', event: 'play', conditions: [{ relation: 'self' }] },
    targets: { kind: 'participant', participant: 'holder', conditions: [] },
    attribute: 'health', amount: -1 });
}

function defaultEffect() {
  return { trigger: { kind: 'event', event: 'play', conditions: [{ relation: 'self' }] },
    targets: { kind: 'participant', participant: 'holder', conditions: [] },
    attribute: 'attack', amount: 1 };
}

// ── trigger normalization: the builder edits the NATIVE resolver form ────────────────
// Legacy content (trigger string + subject + subject_elements) converts on first render,
// exactly the way the game parses it (see TriggerResolver.from_legacy).
const LEGACY_TRIGGER_EVENTS = {
  on_play: ['play', false], on_death: ['death', false], on_attack: ['attack', true],
  on_damage_taken: ['struck', true], permanent: ['play', false],
  on_turn_start: ['turn_start', false], on_turn_end: ['turn_end', false], on_activate: ['activate', false],
};

function normalizeTrigger(e) {
  if (e.trigger && typeof e.trigger === 'object') return;
  const [event, isDual] = LEGACY_TRIGGER_EVENTS[e.trigger || 'on_play'] || ['play', false];
  const conds = [];
  if (e.subject === 'ally' || e.subject === 'enemy') conds.push({ relation: e.subject });
  else if (e.subject !== 'any') conds.push({ relation: 'self' });
  if (e.subject_elements && e.subject_elements.length) conds.push({ composition: e.subject_elements.slice() });
  if (isDual) {
    // the legacy subject was the attacker for on_attack, the struck unit for on_damage_taken
    e.trigger = e.trigger === 'on_damage_taken'
      ? { kind: 'dual_event', event, origin_conditions: [], destination_conditions: conds }
      : { kind: 'dual_event', event, origin_conditions: conds, destination_conditions: [] };
  } else {
    e.trigger = { kind: 'event', event, conditions: conds };
  }
  delete e.subject;
  delete e.subject_elements;
}

// Legacy targeting_policy + top-level conditions → the native "targets" object, exactly
// the way the game maps it (TargetResolver.from_legacy — implicit scopes become relation
// conditions; `subject` follows the normalized trigger's event).
function normalizeTargets(e) {
  if (e.targets && typeof e.targets === 'object') { delete e.conditions; delete e.targeting_policy; return; }
  const conds = (e.conditions || []).slice();
  const p = e.targeting_policy || 'self';
  const subjectIsDestination = e.trigger && typeof e.trigger === 'object' && e.trigger.event === 'struck';
  const map = {
    self: { kind: 'participant', participant: 'holder', conditions: conds },
    single_nearest: { kind: 'auto', criterion: 'nearest', conditions: [{ relation: 'enemy' }, ...conds] },
    single_random: { kind: 'auto', criterion: 'random', conditions: [{ relation: 'enemy' }, ...conds] },
    all_enemies: { kind: 'all', conditions: [{ relation: 'enemy' }, ...conds] },
    all_allies: { kind: 'all', conditions: [{ relation: 'ally' }, ...conds] },
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
  else if (kindKey === 'participant') e.targets = { kind: 'participant', participant: 'holder', conditions: conds };
  else e.targets = { kind: kindKey, conditions: conds };
}

// Rebuild the trigger object for a newly picked event, carrying the primary condition list over.
function retargetTrigger(e, eventKey) {
  const t = e.trigger;
  const primary = (t.kind === 'dual_event' ? t.origin_conditions : t.conditions) || [];
  if (eventKey === 'transient') e.trigger = { kind: 'transient' };
  else if (eventKey === 'attack' || eventKey === 'struck')
    e.trigger = { kind: 'dual_event', event: eventKey, origin_conditions: primary, destination_conditions: [] };
  else e.trigger = { kind: 'event', event: eventKey, conditions: primary };
}

// ── condition editor ─────────────────────────────────────────────────────────
const COND_KINDS = [
  { value: 'attribute', label: 'Stat check' },
  { value: 'status', label: 'Has / lacks a status' },
  { value: 'composition', label: 'Made of / not made of' },
  { value: 'relation', label: 'Relationship to this card' },
];

function condKindOf(c) {
  return c.relation != null ? 'relation'
    : c.status != null ? 'status'
    : c.composition != null ? 'composition' : 'attribute';
}

function renderCondition(c, ctx, onChange, onRemove) {
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
        else if (e.target.value === 'relation') Object.assign(c, { relation: 'self' });
        else Object.assign(c, { attribute: 'health', comparator: 'lte', value: 3 });
        onChange(); renderInto();
      },
    });
    for (const o of COND_KINDS) kindSel.append(el('option', { value: o.value, text: o.label, selected: condKindOf(c) === o.value }));

    const row = el('div', { class: 'frow' });
    row.append(fld('Condition type', kindSel));
    const k = condKindOf(c);
    if (k === 'relation') {
      row.append(
        fld('Must be', selectInput(c, 'relation', (ctx.vocab.relations || ['self', 'ally', 'enemy'])
          .map(r => ({ value: r, label: labelOf('relation', r) })), onChange)),
      );
    } else if (k === 'status') {
      row.append(
        fld('Presence', boolSelect(c, 'present', 'must HAVE the status', 'must NOT have it', onChange)),
        fld('Status', statusPicker(c, 'status', ctx, onChange)),
      );
    } else if (k === 'composition') {
      if (!Array.isArray(c.composition)) c.composition = c.composition ? [c.composition] : [];
      row.append(
        fld('Presence', boolSelect(c, 'present', 'must contain any of…', 'must contain NONE of…', onChange)),
        el('div', { class: 'fld wide' },
          el('span', { class: 'lab', text: 'Elements / pieces' }),
          chipSet(c.composition, ctx.vocab.elements.concat(ctx.vocab.pieces), onChange,
            id => labelOf('element', id) !== id ? labelOf('element', id) : labelOf('piece', id))),
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

function statusPicker(obj, key, ctx, onChange) {
  const ids = ctx.statusIds();
  if (ids.length === 0) return textInput(obj, key, onChange, 'status id');
  if (obj[key] && !ids.includes(obj[key])) ids.unshift(obj[key]);
  return selectInput(obj, key, ids, onChange);
}

// ── effect editor ────────────────────────────────────────────────────────────
// ctx: { vocab, statusIds(), ownerNoun }
// Shared "conditions" section — targeting on EVERY effect kind is gated by the same list.
function conditionSection(e, ctx, localChange, labelWhenSome) {
  if (!e.conditions) e.conditions = [];
  const condWrap = el('div');
  const renderConds = () => {
    condWrap.replaceChildren();
    condWrap.append(el('span', { class: 'lab subtle', text: e.conditions.length ? labelWhenSome : '' }));
    e.conditions.forEach((c, i) => {
      condWrap.append(renderCondition(c, ctx, localChange, () => {
        e.conditions.splice(i, 1); localChange(); renderConds();
      }));
    });
    condWrap.append(el('button', { class: 'ghost small list-add', text: '+ add target condition', onclick: () => {
      e.conditions.push({ attribute: 'health', comparator: 'lte', value: 3 });
      localChange(); renderConds();
    } }));
  };
  renderConds();
  return condWrap;
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
      obj[key].push({ relation: 'self' });
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
      onchange: ev => { coerceEffectKind(e, ev.target.value); onChange(); renderInto(); },
    });
    for (const o of EFFECT_KINDS) kindSel.append(el('option', { value: o.value, text: o.label, selected: kind === o.value }));

    card.append(el('div', { class: 'fx-head' }, kindSel, sumEl,
      el('button', { class: 'ghost tiny', text: '✕', title: 'Remove effect', onclick: onRemove })));

    const body = el('div', { class: 'fx-body' });
    card.append(body);

    if (kind === 'modifier') {
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
      body.append(el('div', { class: 'frow' },
        fld('Rewrites', selectInput(e, 'intercept', [{ value: 'damage', label: 'damage' }], localChange),
          'the stat mutation being rewritten'),
        fld('Only from', selectInput(e, 'channel', [
          { value: 'attack', label: 'unit strikes (auto-attacks)' },
        ], localChange, { optional: true, emptyLabel: 'any source (spells, poison, strikes…)' })),
        fld('Holder must be', selectInput(e, 'role', [
          { value: 'target', label: 'the one being hit (armor / barrier)' },
          { value: 'source', label: 'the one causing it (blind)' },
        ], localChange)),
      ));
      body.append(el('div', { class: 'frow' },
        fld('Operation', selectInput(e, 'op', [
          { value: 'mul', label: 'multiply the amount' }, { value: 'add', label: 'shift the amount' },
        ], localChange), 'multiply ×0 = full block; shift −3 = armor that shaves 3'),
        fld('Amount', numInput(e, 'amount', localChange, { float: true, step: 'any' }), null, 'narrow'),
        fld('Chance', numInput(e, 'chance', localChange, { float: true, step: 0.05, min: 0, max: 1, optional: true, placeholder: '1.0' }),
          'roll per hit, 0–1; empty = always', 'narrow'),
      ));
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
          fld('Which participant', selectInput(tg, 'participant', (ctx.vocab.participants || ['holder', 'origin', 'destination'])
            .map(p => ({ value: p, label: labelOf('participant', p) })), localChange),
            'origin/destination need an event — nothing is targeted on plain use'),
        ));
      }
      // The two slots are the ABSTRACT participants — same for every event. The event-specific
      // noun is only a parenthetical hint, so the UI teaches the model instead of hiding it.
      if (t.kind === 'event') {
        rows.push(participantConditionSection(t, 'conditions', ctx, localChange,
          'ORIGIN' + originHint(t.event) + ' must satisfy:'));
      } else if (t.kind === 'dual_event') {
        if (!t.origin_conditions) t.origin_conditions = [];
        if (!t.destination_conditions) t.destination_conditions = [];
        rows.push(participantConditionSection(t, 'origin_conditions', ctx, localChange,
          'ORIGIN' + originHint(t.event) + ' must satisfy:'));
        rows.push(participantConditionSection(t, 'destination_conditions', ctx, localChange,
          'DESTINATION' + destinationHint(t.event) + ' must satisfy:'));
      }

      if (kind !== 'custom') {
        rows.push(el('div', { class: 'frow' },
          fld('Change stat', selectInput(e, 'attribute', ctx.vocab.effectAttrs.map(a => ({ value: a, label: labelOf('attr', a) })), localChange, { optional: true, emptyLabel: '(no stat change)' })),
          fld('By', numInput(e, 'amount', localChange, { optional: e.attribute == null, placeholder: '0' }),
            'health: + heals, − damages. damage_taken: positive number of damage.', 'narrow'),
        ));
        // status payload
        const hasStatus = !!(e.status && e.status.id != null);
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
            el('div', { class: 'fld narrow', style: 'justify-content:flex-end' },
              el('button', { class: 'ghost tiny', text: '✕ no status', onclick: () => { delete e.status; localChange(); renderStatus(); } })),
          ));
        };
        renderStatus();
        rows.push(stWrap);
      }

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
  function renderInto() {
    container.replaceChildren();
    effects.forEach((e, i) => {
      container.append(renderEffect(e, ctx, onChange, () => {
        effects.splice(i, 1); onChange(); renderInto();
      }));
    });
    container.append(el('button', { class: 'ghost small list-add', text: '+ add effect', onclick: () => {
      effects.push(defaultEffect()); onChange(); renderInto();
    } }));
  }
  renderInto();
}

// Strip transient/empty fields so the deployed JSON stays clean.
function cleanEffectForDeploy(e) {
  const out = JSON.parse(JSON.stringify(e));
  if (out.trigger && typeof out.trigger === 'object') {
    // native resolver form: prune empty participant lists; the legacy subject keys never
    // coexist with it (normalizeTrigger folded them in)
    for (const k of ['conditions', 'origin_conditions', 'destination_conditions'])
      if (out.trigger[k] && !out.trigger[k].length) delete out.trigger[k];
    delete out.subject;
    delete out.subject_elements;
  }
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
    if (!out.status.id) delete out.status;
  }
  if (out.attribute == null || out.attribute === '') { delete out.attribute; if (out.status || out.custom) delete out.amount; }
  if (out.filter && !Object.keys(out.filter).length) delete out.filter;
  const kind = effectKindOf(out);
  // "kind" is inferred by the game parser for modifier (key) / custom / interceptor,
  // and triggered is the default — keep explicit kind only where the data files do.
  if (kind === 'triggered') delete out.kind;
  return out;
}
