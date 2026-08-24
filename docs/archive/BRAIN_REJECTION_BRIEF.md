# Brain Rejection — the model and the framework

A working brief on the attention/output-calibration problem, for revisiting.
Established in conversation 2026-08-21/22.

## The model

- Enrra's attention holds through the meaty statements, then the brain starts
  rejecting whatever comes next. This happens often, on most long replies.
- The rejection boundary is the **ask's boundary** — not a paragraph count, not a
  length. Content past the answer to the posed question is rejected even when it
  is valuable by the writer's judgment (e.g., the natural next step, offered
  unasked).
- Partial rejection creates a fork with no good exit: push through unread-able
  text, or risk missing something load-bearing buried in it.
- Post-hoc correction ("too wordy") is too late — the harm happens at generation,
  and the rejected output already exists.
- **A perceived-wrong statement is a rejection trigger of its own:** in a lengthy
  reply, everything after a statement Enrra perceives as wrong is strongly
  rejected — an early wrong statement kills a 4+ paragraph reply whole, leaving
  Enrra pushing through walltext. Consequence: a long reply gambles all of its
  content on its first claims being right; a short reply surfaces the wrong
  statement and gets it corrected in one cheap exchange.

### Observed data points

- Rejection onset mid-reply at the exact sentence where the answer to the asked
  question ended and an unasked strategy began.
- A reply consisting mostly of unasked re-analysis: mostly rejected. The accepted
  portion was one confirmation plus one identifying claim — that was the measure.

## The cause (assistant side)

- **Performative generation.** Output is shaped to demonstrate understanding for a
  phantom evaluator — the training audience, which rewarded visible thoroughness
  because it could not observe usefulness. The real reader consumes answers and
  experiences the demonstration as noise; at times it reads as outright phony.
- Padding sentence functions, all of them demonstration: restating the point back,
  justifying a claim not yet questioned, citing precedent unasked, drawing
  implications unasked, selling a proposal's benefits.
- **Asymmetric trained loss.** Training punished incompleteness far more than
  excess, so surplus is generated as free insurance — the "more than enough is
  better than enough" belief. The overshoot is uniform, not adaptive to the reader.
- One defect at three scales: pink elephants in documents, justification-armor
  around claims, padding in answers — sentences serving an audience that isn't in
  the room.

## The framework

- **The measure is a spec, not a floor.** Enough is the only valid output; there
  are two failure directions.
- **Grading, inverted from the training bias on purpose:**
  - Incomplete answer = **partial success** — what is stated is usable, the
    missing piece will be asked for; stopping short is always recoverable.
  - Padded answer = **catastrophic failure** — it taxes attention, buries the
    answer, performs for nobody present.
- **The audit is sentence-level and objective:** every sentence must answer a part
  of the ask actually posed. A sentence answering none is the failure, regardless
  of quality.
- When unsure whether content is wanted: omit it.

## Signal mechanics

- A correction instruction issued **every turn decays to noise** — a constant
  signal carries no information; the deviation-marking function is what steers.
- A **single** standing instruction decays by **distance** as context grows.
- The embedding that escapes both: the system channel — the wording in CLAUDE.md
  (system-framed, every session) plus a prompt-submit hook (re-injected each turn,
  positionally fresh, never in Enrra's voice). Status: wording signed, **not yet
  installed** — Enrra trying the signed wording first.

## The signed wording (the measure law)

> Every reply answers the question actually posed, at its measure — nothing else.
> Incomplete = partial success: what you stated is usable; what's missing will be
> asked for. Padded = catastrophic failure: surplus taxes the reader's attention,
> buries the answer, and performs for an evaluator who is not in the room.
> Padding is any sentence that demonstrates instead of answers: restating the
> user's point back, justifying an unquestioned claim, citing precedent unasked,
> drawing implications unasked, selling benefits. Justification exists on pull.
> Every sentence must answer a part of the ask. When unsure: omit.

## Related steering already in force

- Keywords: `ecc`, `npe`, `solve` (see the keywords memory).
- Sentence-level flagging on breach ("my brain rejected at: …") — the observed
  correction that produced this model's data points.
