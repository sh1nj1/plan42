# Complexity budget

Three CI gates keep the codebase from diverging as it grows. They are cheap on
purpose — together they add roughly six seconds of CI time — because a gate that
slows everyone down gets removed.

| Gate | What it stops | Where |
|------|---------------|-------|
| Complexity ratchet | Any class, module, method or block growing past the size it has at the merge base | `complexity` job, `bin/complexity_check` |
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
checks out the merge base into a throwaway `git worktree`, runs RuboCop's
`Metrics` department over both trees, and compares them entity by entity. One
file drives it: **`.rubocop_metrics.yml`**, the budget that decides which
entities are worth measuring. It is not used by `bin/rubocop`; the omakase house
style stays as it is.

The rules:

1. An entity over budget at the merge base may shrink but not grow.
2. An entity not over budget at the merge base must fit `.rubocop_metrics.yml`.
   New code gets no amnesty from old debt.
3. The budget cannot be loosened. Exactly two edits to `.rubocop_metrics.yml`
   pass — lowering a `Max`, and shrinking `AllCops/Exclude` — and every other
   change to it is reported.
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

The ratchet stops *growth*. It does not shrink the 430 entities already over
budget, and it can be routed around by adding a hundred small files instead of
one big one. Neither is a gap a PR gate can close.

For that, use the churn×complexity data — files that are both large and
frequently edited — to allocate a refactoring budget each quarter. That belongs
in planning, not in CI: a report that does not block controls nothing, and a
blocking gate cannot make anyone delete code.

## Rejected alternatives

- **A committed baseline snapshot.** Tried first, and it is what the "Why the
  merge base" section above is about. It goes stale the moment `main` moves and
  its only escape hatch launders regressions.
- **A test-to-app LOC ratio floor.** The core already has a healthy 1.51 ratio
  *and* the god objects. Test LOC is trivially gamed with fixture style, mocks,
  and duplicated setup — it is a lagging indicator dressed as a leading one.
- **A core public-API coupling gate.** Real signal, but multiple days of work
  plus ongoing threshold tuning, against a coverage config change that costs
  nothing and lands today.
- **Enforcing "all extension goes through `IntegrationRegistry`".** See above:
  it contradicts the documented architecture, and a test that contradicts the
  docs gets deleted, not obeyed.
