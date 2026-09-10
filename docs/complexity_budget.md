# Complexity budget

Three CI gates keep the codebase from diverging as it grows. They are cheap on
purpose — the ratchet measures two languages twice each in about ten seconds —
because a gate that slows everyone down gets removed.

| Gate | What it stops | Where |
|------|---------------|-------|
| Complexity ratchet | Any class, module, function, method or block — Ruby or JavaScript — growing past the size it has at the merge base | `complexity` job, `bin/complexity_check` |
| Engine boundary | The core engine taking a dependency on a satellite engine | `EngineBoundaryTest`, runs with `rake test` |
| Coverage patch gate | Ruby diffs landing under 80% covered | Codecov, `codecov.yml` |

## Why these three

Measured on 2026-08-11, before any of this existed:

- **67.4%** of app code lives in the core engine (36,306 of 53,833 lines), and
  30% of all app code is in one directory, `engines/collavre/app/services`.
- Core app code grew **+70%** then **+65%** over the last two quarters. At that
  rate it is 91k lines by 2027-02.
- Over the last 90 days the core saw **+90,368 / -6,767** lines — an added-to-
  deleted ratio of **13.4 : 1**. Refactoring is effectively not happening.
- Not one CI gate constrained any of it: RuboCop runs omakase, which disables
  every `Metrics` cop, and Codecov was informational.

The Ruby ratchet landed first and left half the engine unmeasured. Measured on
2026-09-10:

- The core engine ships **35,390 lines of non-test JavaScript** across 161
  files, against 40,153 lines of core Ruby — and the two largest source files in
  the engine are both JavaScript.
- There was **no ESLint in the repository at all**: no config file, no lint job,
  no devDependency. Nothing measured any of it, and "no explicit configuration"
  is not the same as "no rules" only when there is a default to fall back on.
  There was none.

The divergence is *inside* the core, not across engine boundaries — the
`collavre` → `collavre_*` rule is clean in application code, with one recorded
exception in a migration. So the ratchet is the primary gate and the boundary
test is cheap insurance.

## The ratchet

```
bin/complexity_check              # the gate: compare against merge-base(HEAD, origin/main)
bin/complexity_check --base REF   # compare against something else
bin/complexity_check --report     # just list what is over budget right now
```

There is nothing to commit and nothing to keep in sync. `bin/complexity_check`
checks out the merge base into a throwaway `git worktree`, measures both trees,
and compares them entity by entity. Two files drive it:

- **`.rubocop_metrics.yml`** — RuboCop's `Metrics` department over Ruby app code.
  It is not used by `bin/rubocop`; the omakase house style stays as it is.
- **`.eslint_metrics.yml`** — ESLint's size and complexity rules over the core
  engine's JavaScript. See [The JavaScript half](#the-javascript-half).

Both languages land in one hash of `path | rule | entity` keys, so the waiver
format, the comparison and the reporting below are the same code for both.

The rules:

1. An entity over budget at the merge base may shrink but not grow.
2. An entity not over budget at the merge base must fit `.rubocop_metrics.yml`.
   New code gets no amnesty from old debt.
3. The budget cannot be loosened. Exactly two edits to `.rubocop_metrics.yml`
   pass — lowering a `Max`, and shrinking `AllCops/Exclude` — and every other
   change to it is reported. `.eslint_metrics.yml` allows three: lowering a
   threshold, widening `include`, and shrinking `exclude`.
4. The only escape hatch is a waiver in `.complexity_waivers.yml`, which needs a
   non-blank owner, a non-blank reason, and an expiry no more than 90 days out.
   An expired or blank-field waiver fails CI.

An improvement produces no output at all. That is worth stating explicitly
because the first version of this gate blocked on it.

### Why the merge base and not a committed baseline

The first design committed a `.complexity_baseline.yml` snapshot of every
over-budget entity and compared the working tree against it. It is the obvious
design, and it does not survive a moving `main`.

It failed on its own PR. Eleven entities the branch had never touched were
reported, and four of them were *improvements that had landed on main* —
`Collavre::User` shrinking from 323 lines to 295 turned the PR red. Every open
PR in the repo would have gone red the same way, on someone else's refactor,
within a day of merging.

The only way out was `--regenerate`, which rewrote the snapshot from the working
tree. In a drifted state that also copies main's *regressions* into the
baseline, laundering them into the permanent record. So the documented rule
"never regenerate just to make CI green" described the one action the tool made
unavoidable.

Measuring the merge base deletes the failure mode rather than guarding it:

- **Main's drift is invisible.** The merge base moves with main, so only what
  this branch changed can fail.
- **An improvement is just an improvement.** There is no record to re-sync, so
  rule 3 of the old design ("regenerate in the same PR") no longer exists.
- **A RuboCop upgrade shifts both sides identically.** The old design needed a
  whole `Gemfile.lock` comparison to catch an upgrade silently deleting debt;
  here it cancels out by construction.
- **There is no snapshot to loosen**, so `--verify-baseline`, `--regenerate`,
  and the sibling-anchor tamper detection that guarded them all went away with
  it — about 1,600 lines of code, tests and documentation.

The cost is that the ratchet is **relative, not absolute**. A branch cut before
an improvement lands has an older merge base, so it could regrow that entity
back to its earlier size without tripping. Requiring branches to be current with
`main` before merge closes it, and the squash-merge workflow already rebases.
That is a much smaller hole than a gate the team switches off in week two
because it reddens unrelated PRs.

### Which base the CI job passes

The `complexity` job passes the base **branch**, not `github.event.pull_request.base.sha`.

The two are not the same thing, and the difference is not academic. `base.sha`
is the base tip as of the last `opened`/`synchronize` event on the PR: it is a
snapshot of the base at the moment *this* branch last pushed, and it does not
move when the base branch does. `actions/checkout` on a pull request checks out
`refs/pull/N/merge`, which GitHub *does* recompute whenever the base moves.
Measuring the second against the first blames this PR for every sibling PR that
landed in between.

That is not a hypothetical either. On the branch that introduced this file, the
job reported eight offenses in `creative_row_editor.js`, `popup_fullscreen.js`
and `creative_save_state.js` — three files it had never touched — because two
sibling PRs had merged into the integration branch since its last push. It
happened twice, and on an integration branch collecting eight parallel PRs it
would have happened on nearly every run.

Passing `origin/$BASE_REF` makes the baseline `merge-base(HEAD, base tip)`.
Since the checkout has the base tip as an ancestor, that *is* the base tip, so
what gets measured is exactly what this branch adds to the base as it stands
right now. The branch no longer has to keep merging the base in to stay green.

To reproduce a CI result locally, build the same tree the job sees:

```sh
git fetch origin "refs/pull/$PR/merge:refs/ci-merge" && git checkout refs/ci-merge
bin/complexity_check --base origin/<base branch>
```

Note that `--base` is resolved through `git merge-base`, so running it on a
branch that has *not* merged the base in compares against the fork point and
reports base-side entities as new. That is the local mirror of the same
mismatch, and checking out the merge ref is what removes it.

### Rule 3: why the budget still needs its own check

Both trees are measured with **this branch's** `.rubocop_metrics.yml`, on
purpose: measuring the base with its own budget would make a PR that *tightens*
a `Max` report every pre-existing entity the tightening newly caught as brand-new
debt.

The price of that choice is that raising a `Max` is invisible to the comparison —
RuboCop simply stops emitting those offenses on both sides at once and the
difference is zero. Measured on this repo, `Metrics/MethodLength: 25 -> 200`
silences 160 of 430 entities and reports nothing. So the budget file is compared
against the merge base's copy directly.

Rule 3 is an allowlist rather than a list of known tricks, because `Max` is only
the loudest way to loosen a cop. A per-cop `Exclude: ['**/*']` under
`Metrics/MethodLength` silences it repository-wide while the line above still
reads `Max: 25`; `Include`, `AllowedMethods`, `AllowedPatterns` and `CountAsOne`
do the same more quietly, and `inherit_mode` changes whether `AllCops/Exclude`
merges with the inherited list or replaces it. Every one is a real bypass, and
the next RuboCop release may add another. So anything that is not "lower a `Max`"
or "shrink `AllCops/Exclude`" is reported.

A genuine tightening trips this too. It is not blocked — apply the
`complexity-baseline-reset` label and the budget comparison is skipped, which is
the point: the budget moves where a reviewer can see it. Applying a label does
not re-trigger CI, so re-run the `complexity` job afterwards.

### Why not `.rubocop_todo.yml`

`rubocop --auto-gen-config` raises each cop's `Max` to the worst value it
observes. In this repo that means `MethodLength: 240`, `ClassLength: 1731`,
`AbcSize: 267.4`. That does not enable the cop, it disables it with extra steps:
a brand-new 200-line method would pass. The other auto-gen mode, per-file
`Exclude`, is worse — an excluded file becomes permanently invisible to that cop
and can grow without limit, which is exactly the amnesty a god object wants.

### Why the budget is not RuboCop's defaults

RuboCop's defaults put 1,846 app-code entities in violation, meaning new code
would have to be stricter than 90% of what is already here. Every `Max` in
`.rubocop_metrics.yml` instead sits near the 75th percentile of today's
violators — tight enough that crossing it is a real smell, loose enough that
ordinary Rails code passes without ceremony. Tighten them as the debt drains.

### Entity keys

An entity is identified by its fully-qualified name, not its line number, so
inserting code above a method does not make it look like a different entity in
the two measurements:

```
engines/collavre/app/services/collavre/agent_orchestrator.rb | Metrics/ClassLength | Collavre::AgentOrchestrator
engines/collavre/app/services/collavre/agent_orchestrator.rb | Metrics/MethodLength | Collavre::AgentOrchestrator#dispatch
```

Names come from a Prism parse of the source. `Metrics/BlockNesting` offenses do
not sit on a definition, so those fall back to a normalised source line, written
with a leading `~`.

Sibling scopes that share a name — `items.each do` twice in one method, or a
class reopened in the same file — are numbered from the second one on
(`…#run[block:each](2)`). Without that they share a key, and only the larger is
recorded, so a second block over the budget would hide behind its sibling. The
ordinal counts within the parent scope, so edits elsewhere in the file leave it
alone.

An ordinal is a position, and a position is not an identity: delete the first of
two same-named siblings and the second inherits the first's key, and with it the
first's measured size. Under the committed-baseline design this was a silent
bypass worth several hundred lines of anchor-tracking to detect. Here it is only
a mislabel — the surviving block is compared against the deleted one's number,
so the gate is wrong in either direction by the difference between two siblings
in the same scope, and a real regression in that scope still has to get past
whichever of the two numbers it is compared to. Not free, but not worth the
machinery it cost.

Chained blocks — `items.each do … end.map do … end` — share a start line *and* a
start column, because a block offense covers the whole `send + block` range and
the outer send begins at the receiver. So an entity is looked up by its full
line range, not its first line. Prism's node ranges match RuboCop's offense
ranges exactly for classes, defs and blocks; the first-line map is kept as the
fallback for offenses that do not sit on a scope.

Tests are excluded. A 900-line test class is a list, not a god object: it has no
callers, holds no shared mutable state, and splitting it buys nothing. Test bloat
is real, but it is a coverage-quality problem, not a coupling one, and mixing it
in would bury the app-code signal under thousands of block-length offenses.

## The JavaScript half

`.eslint_metrics.yml` is the budget; `bin/js_complexity.mjs` and
`lib/js_complexity/` are the measurement. It prints the same
`{"path | rule | entity": value}` shape the Ruby measurement produces, and
`bin/complexity_check` merges the two before comparing, so everything above —
the merge base, the waivers, rules 1 to 4 — applies unchanged.

### The budget

Unlike the Ruby side, where RuboCop's defaults put ~90% of entities in violation
and the budget had to be set at the 75th percentile of the violators, ESLint's
documented defaults were already within reach. Measured over the 161 files the
budget selects, on 2026-09-10:

| Rule | Budget | Entities | Over budget | Ruby counterpart |
|------|--------|----------|-------------|------------------|
| `complexity` | 13 | 3,083 | 88 (2.9%) | `Metrics/CyclomaticComplexity` |
| `max-depth` | 3 | 3,402 | 19 (0.6%) | `Metrics/BlockNesting` |
| `max-lines` | 300 | 161 | 21 (13.0%) | `Metrics/ClassLength` |
| `max-lines-per-function` | 50 | 3,036 | 78 (2.6%) | `Metrics/MethodLength` |
| `max-nested-callbacks` | 10 | 1,001 | 0 (0.0%) | — |
| `max-params` | 4 | 1,880 | 8 (0.4%) | `Metrics/ParameterLists` |

214 entities are over it, against 394 on the Ruby side. They are grandfathered:
they may shrink but not grow. The budget is what *new* code has to fit, and
ordinary Stimulus controllers and modules already fit it.

`max-nested-callbacks` sits at ESLint's default because nothing violates it —
the same reasoning that keeps `Metrics/BlockNesting` at RuboCop's default.
`max-lines` and `max-lines-per-function` skip blank lines and comments, because
RuboCop's counters do; otherwise the same file measures differently on the two
sides and a comment block reads as growth.

### The budget file holds only numbers

`.eslint_metrics.yml` has three keys — `include`, `exclude` and `rules` — and
`rules` maps a rule name to an integer. Rule options that are not thresholds
(`skipBlankLines`, `IIFEs`) live in `lib/js_complexity/measure.js`, and there is
no per-file override syntax at all.

That is the difference between this budget and a real `eslint.config.js`, and it
is the point. Rule 3 on the Ruby side needs a long allowlist because a `Metrics`
cop can be silenced through `Exclude`, `Include`, `AllowedMethods`,
`AllowedPatterns` or `CountAsOne` while its `Max` still reads as strict. Here
there is nothing to silence a rule *with*: three keys, and all three are
compared. Inline `eslint-disable` comments are refused as well
(`noInlineConfig`), so a directive cannot switch the gate off from inside a
source file either.

### Why ESLint's `Linter` and not the `ESLint` class

The base side of the ratchet is a detached worktree of the merge base. It has no
`node_modules` and no ESLint config of its own, and it must not have one:
measuring each side with its own budget is what makes a PR that *tightens* a
threshold report every pre-existing entity as brand-new debt. `Linter#verify`
takes the config as a value and resolves nothing from the tree it is reading, so
this branch's ESLint and this branch's budget are applied to both sides. The
`ESLint` class would search the measured tree for a config file.

### Entity keys in JavaScript

Same problem as the Ruby side, same shape of answer, different parser. Names are
built from an ESTree walk (`lib/js_complexity/entity_map.js`):

```
engines/collavre/app/javascript/controllers/comments/topics_controller.js | max-lines | (file)
engines/collavre/app/javascript/modules/creative_row_editor.js | max-lines-per-function | setupEditorSession
engines/collavre/app/javascript/components/InlineLexicalEditor.jsx | max-lines-per-function | Toolbar>clearFormatting[useCallback]
engines/collavre/app/javascript/controllers/comments/form_controller.js | complexity | default#handleSend>[doFetch().then().then]
```

- A class member reads `Editor#save`, a static `Editor.create`, and a getter
  `Editor#get draft` — without the kind, a `get`/`set` pair would collide into an
  ordinal pair that reads as two unrelated members.
- An anonymous function takes the name it is bound to (`const submit = …` →
  `submit`), or, if it is bound to nothing, the *whole callee* of the call it is
  passed to (`[this.element.addEventListener]`, `[rows.map]`). This is what the
  Ruby side does for blocks, with the receiver kept: `[map]` on its own turns
  every `.map` in a method into a twin of every other, and twins are the only
  case where identity has to fall back on something other than a name.
- A callee keeps its chain, rendered as `foo()`: the two callbacks in
  `load().then(a).then(b)` are `[load().then]` and `[load().then().then]`, so
  appending a third link leaves both of them where they were.
- A callback whose call is itself bound to something takes that binding too:
  `const handleFiles = useCallback(…)` is `handleFiles[useCallback]`. Every
  callback in a React component is `useCallback`, so without this a component
  with eleven of them has eleven twins, and adding a twelfth moves all eleven
  keys.
- `export default class extends Controller` — every Stimulus controller in the
  engine — is named `default`. "(anonymous class)" would be accurate and
  useless.
- Entities in one scope that still share a name after all of that are **twins**,
  and each is anchored to a digest of its own source: `[rows.map]#2842ca41`.
  See [Twins](#twins) below.
- `max-lines` belongs to `(file)`: it reports on the first line past the limit,
  which belongs to no entity in particular.
- `max-depth` reports on a statement, so it falls back to the enclosing scope
  plus the normalised source line with a leading `~` — the same fallback the
  Ruby side uses for `Metrics/BlockNesting`.

Lookup is by containment rather than by start position, because ESLint does not
report an offense at the node it is about: `getFunctionHeadLoc` puts a method
offense on the method name and an arrow offense on the `=>` token. All of them
are *inside* the entity, so the innermost scope containing the offense is the
right answer in every case.

### Twins

Two entities in one scope can end up with the same name however good the naming
is: two `items.map(…)` callbacks in one method, two identical `if` lines. The
obvious fix is a **position** — first one bare, second one `(2)`, or `(1/2)` and
`(2/2)` to make the group's size part of it. Every version of that idea is
wrong for the same reason: it makes a *slot* the identity, and the entity in
slot 2 after an edit need not be the entity that was in slot 2 before it.

Both ways of reaching that were found by Codex review on PR #1651. Deleting a
twin:

```js
// before                               // after
connect() {                             connect() {
  items.map((row) => { …60 lines… })      items.map((row) => { …58 lines… })
  items.map((row) => { …55 lines… })    }
}
```

Under a bare ordinal the survivor is renamed from `>[items.map](2)` to
`>[items.map]`, the key the *deleted* callback held at 60, so its growth from 55
to 58 is measured against 60 and the gate says nothing. Carrying the group's
size fixes that one — and leaves reordering, which is the same bug wearing a
different hat:

```js
// before: (1/2) = 12, (2/2) = 6       // after: (1/2) = 9, (2/2) = 5
```

Slot 1 reads `9 <= 12` and slot 2 reads `5 <= 6`, so nothing is reported, and
yet the 6-line callback has grown to 9. Concealing growth this way costs an
equal shrink somewhere else in the group, which is a low price for a silent
bypass — and a silent bypass is the one failure mode this whole design exists to
avoid.

So the first move is to **have fewer twins**. Keeping the whole callee, keeping
the call chain, and borrowing the binding a call sits in (see the naming rules
above) between them name all but a handful: of the engine's 214 over-budget
entities, thirteen needed a position before those rules and four after — the
worst being an eleven-way `useCallback` group in one component.

What is left is anchored to an **FNV digest of its own source**, normalised so
that reindenting does not move a key but editing does:

```
Row#connect>[items.map]#2842ca41
Row#connect>[items.map]#5655f759
```

A twin's key now depends on the twin and on nothing around it. Siblings can be
added, deleted or reordered without touching it, and an edit that changes its
measurement changes its key, so growth surfaces as new debt instead of slipping
into a neighbour's baseline. The statement fallback (`~if (a) {`) is anchored
the same way, over the statement's whole span rather than its first line.

Only **byte-identical** twins still take an ordinal — `#2842ca41(1/2)` — and
those measure identically, so any permutation of them is a no-op. One entity in
the engine is in that position; the other three are distinct and now keyed
apart.

"Byte-identical" has to be meant literally, and two rounds of review on #1651
found it was not. Both holes ended the same way — two entities that measure
differently sharing an anchor, falling back on an ordinal, and landing back on
slot identity:

- **The digest was the grouping key.** One 32-bit FNV word collides often enough
  that a brute-force search turns up a pair of ordinary-looking callbacks in
  seconds; `(row) => { total += 91098 }` and `(row) => { total += 802942 }` are
  one such pair. Twins are grouped by their **source text** now, and the digest
  widens a word at a time until distinct bodies have distinct anchors. The first
  width is a plain FNV-1a, so a group that does not actually collide keeps
  exactly the key it always had.
- **Normalisation collapsed newlines.** `max-lines-per-function` counts lines,
  so two callbacks differing only in where a template literal's text wraps
  measured 5 and 4 while normalising to the same string. Normalisation now
  collapses only what the rules cannot see: runs of horizontal whitespace, any
  horizontal whitespace around a line break, and runs of line breaks (the rules
  run with `skipBlankLines`). Every line break that separates content survives.
- **"Line break" meant `\n`.** ESLint splits lines on `\r\n`, `\r`, U+2028 and
  U+2029 as well, so those count too — and U+2028 fell in the "horizontal"
  bucket, collapsing two callbacks that measured 5 and 4 onto one anchor. The
  set now matches ESLint's. `\v` and `\f` are not in it and stay horizontal.

One more, in the statement fallback rather than the digest: **`max-depth` is the
only measurement here that is not a property of the entity's own text.** Two
byte-identical `if (a) { y() }` statements in one function sit at different
depths when one of them is inside another guard, so they measure differently —
and being byte-identical, they shared an anchor and fell back on the ordinal.
The justification for the ordinal did not hold for statements. A statement's
identity carries its nesting depth now:

```js
function handle(p, q, a) {
  if (p) { if (p) { if (a) { y() } } }   // ~if (a) { y() } at depth 3
  if (q) { if (a) { y() } }              // ~if (a) { y() } at depth 2
}
```

Those are two keys, not two slots.

The depth in the key is **ESLint's own**, mirrored from the rule. A first
attempt merely counted enclosing nesting statements, on the argument that the
number only had to *change* when ESLint's changed and that over-counting keeps
entities apart. That was the fifth variant of the same bug. A key has to
*determine* its measurement, and a count that is merely correlated with
ESLint's does not: both `if (a) { y() }` below sit under three enclosing
statements, yet measure 3 and 2, because ESLint does not count an `if` whose
parent is an `if`.

```js
function handle(p, q, a) {
  if (p) { if (p) { if (a) { y() } } }              // enclosing 3, measures 3
  if (q) { x() } else if (q) { if (a) { y() } }     // enclosing 3, measures 2
}
```

Byte-identical and equal-count, they shared an anchor and took an ordinal — and
each was then compared against the other's baseline. On the engine as it stands,
4 of the 19 real `max-depth` offenses had a key whose depth disagreed with the
number ESLint printed.

Mirroring means mirroring the rule's arithmetic rather than a tidied-up version
of it, including one upstream quirk: every nesting statement decrements the
counter on exit, but an `if` under an `if` never incremented it, so an
`if`/`else if`/`else if` chain leaves the counter two *below* where it started
and everything after it measures too shallow. Reproducing that is the point —
the key has to match the number ESLint actually reported, not the one it should
have. `depthsOf` is a single pass written to read like the rule, so an ESLint
upgrade that fixes the quirk is a diff against one function.

Comments are the one thing left that moves a digest without moving a measurement
— `skipComments` is on — so editing a comment inside an over-budget twin re-keys
it. That is the loud direction, and telling comments from their look-alikes
inside strings needs the token stream, which is a lot of machinery for a twin.

The costs, both of which are the gate being loud about something it cannot
attribute rather than quiet about something it can:

- An over-budget twin that shrinks *without getting under budget* has a new
  body, so it has a new key and reads as new debt.
- The digest is only spelled out when a name is shared, so going from one such
  entity to two — or back — renames it.

Both are recoverable three ways: give the callback a name (`const renderRow =
(row) => …`, which ends the tie for good and is usually the right change
anyway), get it under budget, or write a dated waiver. The reverse trade is not
recoverable, because nobody finds out.

The Ruby half still uses a plain ordinal and still has the hole, with the
smaller blast radius its own section describes. Changing it would move every
Ruby entity key at once, which is not this change's business.

### Scope

`engines/collavre/**/*.{js,jsx}`, minus `__tests__` and `engines/collavre/test`.
The core engine and nothing else: this gate is being introduced *for* the core
engine, and `lib/js_complexity` — the measurement itself — is deliberately not
in `include`, so a change to the tool cannot read as engine debt. Adding it is a
one-line change whenever someone wants it, and the tool's own tests live in
`lib/js_complexity/__tests__` either way. Tests are excluded for the reason they
are excluded on the Ruby side, spelled out under
[Entity keys](#entity-keys). The satellite engines hold about 2,800 lines of
JavaScript between them against the core's 35,000 and are not measured; adding
them is a two-line change to `include`, which the budget check allows in that
direction.

### What this change touches outside the engine

The guard's *target* is `engines/collavre`. Nothing under `engines/` is modified
by this change — the gate is new, and the 214 entities already over budget are
grandfathered. What it does add lives outside the engine, because that is where
a repository-wide gate has to live:

| Path | Why it has to change |
|------|----------------------|
| `.eslint_metrics.yml` | The budget. New file. |
| `lib/js_complexity/`, `bin/js_complexity.mjs` | The measurement. New files. |
| `lib/complexity_ratchet/javascript.rb` | Runs the measurement and checks the budget can only tighten. New file. |
| `bin/complexity_check` | Merges the JavaScript measurement into the existing Ruby one; the comparison, the waivers and the reporting are shared rather than duplicated. |
| `.github/workflows/ci.yml` | The existing `complexity` job needs Node and `npm ci` to run the measurement. |
| `package.json`, `jest.config.cjs` | ESLint as a devDependency, and the measurement's unit tests in the existing Jest run. |
| `config/application.rb`, `docs/` | Keeps the CI-only tool out of the autoload path, and documents the above. |

## The engine boundary

`EngineBoundaryTest` fails when a core engine Ruby file names a satellite
constant or loads one of its files by literal path. Both halves are deliberately
small — the whole test is under 300 lines — and it is worth being explicit about
what it is *not*.

**It is not an adversarial gate.** It checks two static, literal things, and it
can be defeated by writing the reference dynamically: `"Collavre" + "Github"`,
`const_get(computed)`, an interpolated require path. Chasing those is an
unbounded surface — every reflection API, every way to build a string — and the
payoff is zero, because defeating the check takes deliberate obfuscation and
deliberate obfuscation is what code review is for. The value is in catching the
*accidental* reference, someone reaching for `CollavreGithub::Account` in core
because it was convenient, and that reference is always written plainly.

This scope is a correction. An earlier revision of this test chased edge cases
through ERB, CSS `image-set()`, JSX generics and `createRequire` shadowing until
it reached 3,668 lines — the largest file in the repository, produced by a PR
whose purpose was to stop files from getting large.

**It is not the `IntegrationRegistry` rule.** `docs/conventions.md` and
`docs/host_architecture.md` both explicitly bless satellites injecting
associations into core models from an initializer, so "all extension goes through
IntegrationRegistry" is not something this test can assert without contradicting
the documented architecture.

**Naming by constant** records the class actually reached, so
`CollavreGithub::Account` rather than `CollavreGithub` — a waiver has to name one
reference, not one engine. The source is lexed rather than grepped, so a comment
or a doc string mentioning an engine is not a violation; both existing mentions
in the core engine are comments. A satellite token preceded by `::` is ignored,
because `Wrapper::CollavreSlack` is Wrapper's own nested constant.

**Loading** covers `require`, `require_relative`, `require_dependency`, `load`
and `autoload` on a bare or `self.` receiver, with a literal string argument.
Paths are normalised with `Pathname#cleanpath`, so traversal
(`require_relative "../../collavre_slack/…"`) is caught.

Both detectors match against the **discovered** engine set rather than a
`collavre_` prefix, so a vendored `collavre_githubish/` directory is not reported
as a dependency on an engine that does not exist. The gemspec dependency check is
the one place the prefix is the right test: a satellite published to RubyGems but
absent from this checkout is still a dependency the core gem cannot declare.

**What gets scanned** is read from `collavre.gemspec`'s own file list, plus the
gemspec itself, filtered to `.rb` / `.rake` / `Rakefile`. It is not a
hand-written glob: the first version globbed `{app,lib,config}/**/*.rb` and
review found shipped code outside it twice — the engine's `.rake` tasks, then
`db/` (154 files). A glob and a packaging manifest maintained separately will
drift.

**`KNOWN_VIOLATIONS`** records the four pre-existing constant references, all in
one 2026-01 migration that encrypts OAuth tokens and reaches
`CollavreGithub::Account` and `CollavreNotion::NotionAccount` behind `defined?`
guards so it runs on installs without those engines. A migration that has run in
production cannot be edited, so they are recorded rather than fixed — but
recording is not amnesty: a separate test asserts each entry is *still* a real
violation, so when the migration is squashed away the stale entry fails instead
of rotting into a blind spot.

Entries name the **exact class reached, once per occurrence**. A waiver written
as the engine namespace (`CollavreGithub`) would cover every present and future
reference to anything under that engine, turning a one-line exception into
permanent amnesty; the multiset form cancels one occurrence each.

Adding an entry is not the normal response to a failure. Invert the dependency
instead: expose a hook from `collavre` and let the satellite register itself.

## What this does not do

The ratchet stops *growth*. It does not shrink the 608 entities already over
budget (394 Ruby, 214 JavaScript), and it can be routed around by adding a hundred small files instead of
one big one. Neither is a gap a PR gate can close.

For that, use the churn×complexity data — files that are both large and
frequently edited — to allocate a refactoring budget each quarter. That belongs
in planning, not in CI: a report that does not block controls nothing, and a
blocking gate cannot make anyone delete code.

## Rejected alternatives

- **A committed baseline snapshot.** Tried first, and it is what the "Why the
  merge base" section above is about. It goes stale the moment `main` moves and
  its only escape hatch launders regressions.
- **`max-statements`.** A genuine rule, and 384 entities exceed ESLint's default
  of 10 — but it measures nearly the same thing as `max-lines-per-function`, and
  adding it would have nearly tripled the over-budget list for a signal already
  covered. The gate is cheap because it is small.
- **A standalone ESLint lint job.** ESLint is in this repository for exactly one
  reason: it is the only thing here that can parse modern JS and JSX well enough
  to measure it. Turning on its correctness or style rules is a separate
  decision with a separate cost — ~35,000 lines of unlinted JavaScript would
  produce thousands of offenses on day one — and bundling it into a complexity
  gate is how a gate gets switched off in week two.
- **A test-to-app LOC ratio floor.** The core already has a healthy 1.51 ratio
  *and* the god objects. Test LOC is trivially gamed with fixture style, mocks,
  and duplicated setup — it is a lagging indicator dressed as a leading one.
- **A core public-API coupling gate.** Real signal, but multiple days of work
  plus ongoing threshold tuning, against a coverage config change that costs
  nothing and lands today.
- **Enforcing "all extension goes through `IntegrationRegistry`".** See above:
  it contradicts the documented architecture, and a test that contradicts the
  docs gets deleted, not obeyed.
