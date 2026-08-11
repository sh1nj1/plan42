# Complexity budget

Three CI gates keep the codebase from diverging as it grows. They are cheap on
purpose — together they add roughly two seconds of CI time — because a gate that
slows everyone down gets removed.

| Gate | What it stops | Where |
|------|---------------|-------|
| Complexity ratchet | Any class, module, method or block growing past its recorded size | `complexity` job, `bin/complexity_check` |
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
bin/complexity_check                          # the gate
bin/complexity_check --regenerate             # after a refactor that shrank something
bin/complexity_check --verify-baseline REF    # what CI runs on a PR
```

Two files drive it:

- **`.rubocop_metrics.yml`** — the budget for *new* entities. Not used by
  `bin/rubocop`; the omakase house style stays as it is.
- **`.complexity_baseline.yml`** — every entity that is *already* over budget,
  pinned at its current value.

The rules:

1. An entity in the baseline may only shrink. Growth fails.
2. An entity not in the baseline must fit `.rubocop_metrics.yml`. New code gets
   no amnesty from old debt.
3. Shrinking an entity requires regenerating the baseline in the same PR, so the
   recorded value always tracks reality and the ratchet only turns one way.
4. The baseline cannot be loosened. `--verify-baseline` fails any PR that raises
   a value or adds a key.
5. The budget cannot be loosened either. The same command allows exactly two
   edits to `.rubocop_metrics.yml` — lowering a `Max`, and shrinking
   `AllCops/Exclude` — and reports every other change to it.
6. The only escape hatch is a waiver in `.complexity_waivers.yml`, which needs a
   non-blank owner, a non-blank reason, and an expiry no more than 90 days out.
   An expired or blank-field waiver fails CI.

Rule 5 exists because rule 4 alone is not enough, and the gap is not obvious:
raising a `Max` makes RuboCop stop emitting the offenses that cop held,
`--regenerate` then deletes their baseline entries, and a deletion is what a
real refactor looks like — so the baseline check waves it through. Measured on
this repo, `Metrics/MethodLength: 25 -> 200` deletes 160 of 438 entries, reports
zero new debt, and turns every gate green while new code inherits the weaker
limit. Deletions cannot simply be rejected (refactors produce them), so the
budget itself is pinned instead.

Rule 5 is an allowlist rather than a list of known tricks, because `Max` is only
the loudest way to loosen a cop. A per-cop `Exclude: ['**/*']` under
`Metrics/MethodLength` silences it repository-wide — 159 baseline entries on this
repo — while the line above still reads `Max: 25`; `Include`, `AllowedMethods`,
`AllowedPatterns` and `CountAsOne` do the same thing more quietly, and
`inherit_mode` changes whether `AllCops/Exclude` merges with the inherited list
or replaces it. Every one of those is a real bypass, and the next RuboCop release
may add another. So anything that is not "lower a `Max`" or "shrink
`AllCops/Exclude`" is reported. A genuine tightening trips this too: it is not
blocked, it goes through `complexity-baseline-reset` like any other budget
change, which is the point — the budget moves where a reviewer can see it.

Two caveats on rule 4. `--verify-baseline` passes when the base ref predates the
baseline file, which is what lets the bootstrap commit land; the residual way
around the gate is therefore to delete `.complexity_baseline.yml` and regenerate
it, which is a several-hundred-line deletion in the diff. And a RuboCop upgrade
that changes how a metric is computed shifts every value at once — that is what
the `complexity-baseline-reset` PR label is for. Applying a label does not
re-trigger CI, so re-run the `complexity` job after adding it.

### Why not `.rubocop_todo.yml`

Because it does the opposite of what it looks like it does.

`rubocop --auto-gen-config` raises each cop's `Max` to the worst value it
observes. In this repo that is:

| Cop | Default | What auto-gen would write |
|---|---:|---:|
| `Metrics/MethodLength` | 10 | **240** |
| `Metrics/ClassLength` | 100 | **1,731** |
| `Metrics/AbcSize` | 17 | **267.4** |

A brand-new 200-line method would pass. That is not enabling the cop, it is
disabling it with extra steps.

The other auto-gen mode, `--auto-gen-only-exclude`, is worse: an excluded file
becomes permanently invisible to that cop and can grow without limit — precisely
the amnesty a god object wants.

Recording the baseline per *entity* avoids both. `agent_orchestrator.rb` is
pinned at ClassLength 391 and its individual methods at their own sizes; a new
method in that same file still has to fit the budget.

### Why the budget is not RuboCop's defaults

RuboCop's defaults put 1,846 app-code entities in violation, meaning new code
would have to be stricter than 90% of what is already here. Every `Max` in
`.rubocop_metrics.yml` instead sits near the 75th percentile of today's
violators — tight enough that crossing it is a real smell, loose enough that
ordinary Rails code passes without ceremony.

Tighten them as the baseline drains. That is the intended direction of travel,
and the baseline gives you the arithmetic to argue about it.

### Entity keys

A baseline entry is keyed by the entity's fully-qualified name, not its line
number, so inserting code above a method does not invalidate its entry:

```yaml
engines/collavre/app/services/collavre/agent_orchestrator.rb:
  Metrics/ClassLength:
    Collavre::AgentOrchestrator: 391
  Metrics/MethodLength:
    Collavre::AgentOrchestrator#dispatch: 38
```

Names come from a Prism parse of the source. `Metrics/BlockNesting` offenses do
not sit on a definition, so those fall back to a normalised source line, written
with a leading `~`.

Sibling scopes that share a name — `items.each do` twice in one method, or a
class reopened in the same file — are numbered from the second one on
(`…#run[block:each](2)`). Without that they share a key, and only the larger of
the two is recorded, so a second block over the budget would hide behind a
sibling already in the baseline. The ordinal counts within the parent scope, so
edits elsewhere in the file leave it alone; adding or reordering same-named
siblings does shift it, and shows up as a new entity to fix or waive.

Chained blocks — `items.each do … end.map do … end` — need more than an ordinal,
because they share a start line *and* a start column: a block offense covers the
whole `send + block` range, and the outer send begins at the receiver. So an
entity is looked up by its full line range, not its first line. Prism's node
ranges match RuboCop's offense ranges exactly for classes, defs and blocks; the
first-line map is kept as the fallback for offenses that do not sit on a scope.

Tests are excluded. A 900-line test class is a list, not a god object: it has no
callers, holds no shared mutable state, and splitting it buys nothing. Test bloat
is real, but it is a coverage-quality problem, not a coupling one, and mixing it
in would bury the app-code signal under thousands of block-length offenses.

## The engine boundary

`EngineBoundaryTest` fails when a core engine file names a satellite constant or
loads one of its files. It asserts only that half of the rule — see *Rejected
alternatives* for why the `IntegrationRegistry` half is not enforced here.

**Loading** covers every entry point that resolves through `$LOAD_PATH`:
`require`, `require_relative`, `require_dependency`, `load`, and `autoload`.
Each reaches a satellite file while leaving behind no constant and no gemspec
entry, so all five are invisible to the other two checks. Targets are read by
walking the argument list after the call and normalized with
`Pathname#cleanpath`, so traversal (`require_relative "../../collavre_slack/..."`)
is caught and prose that merely mentions an engine is not.

The receiver rule differs by method. `require` and `load` count only on `Kernel`
— a bare call or an explicit `Kernel.` receiver — because
`YAML.load "config/collavre_slack/x.yml"` is a file read, not a dependency, and a
gate that cries wolf gets deleted. `autoload` counts on any receiver, because it
is `Module#autoload` and a module receiver is its ordinary form:
`Collavre.autoload :Notion, "collavre_notion/foo"` registers the constant and
loads that file on first reference.

**Naming** covers a satellite class written into a string literal:
`class_name: "CollavreNotion::NotionAccount"`, `"CollavreGithub::Account".constantize`,
`const_get`, or an STI `type` value inside a SQL heredoc. Rails resolves all of
them to the real class at run time, and the core engine breaks when the satellite
renames it — but none produce a `CONSTANT` token, a gemspec entry, or a require.
The check is deliberately not keyed on the API that consumes the string:
enumerating `class_name` / `constantize` / `const_get` / `serialize` is the same
losing game that produced four rounds of misses on the loader check. A satellite
class name in a string literal in core code is the violation, whatever reads it
afterwards. Comments lex as `COMMENT` rather than `STRING_CONTENT`, so prose
about an engine is still fine.

**What gets scanned** is read from `collavre.gemspec`'s own file list, plus the
gemspec itself, filtered to `.rb` / `.rake` / `.erb` / `Rakefile`. It is not a
hand-written glob: the first version globbed `{app,lib,config}/**/*.{rb,erb}`
and review found shipped Ruby outside it twice — the engine's `.rake` tasks,
then `db/` (154 files) and the `Rakefile`. A glob and a packaging manifest
maintained separately will drift. Reading the manifest means whatever the engine
ships is scanned by construction, including directories added later.

**`KNOWN_VIOLATIONS`** records the two pre-existing references, both migrations.
The 2026-01 OAuth token encryption reaches `CollavreGithub::Account` and
`CollavreNotion::NotionAccount` by constant, guarded by `defined?` so it runs on
installs without those engines; the 2026-05 dismissed-at backfill matches an STI
`type = 'CollavreGithub::GithubPrChannel'` inside its SQL. A migration that has
run in production cannot be edited, so both are recorded rather than fixed — but
recording is not amnesty: a separate
test asserts each entry is *still* a real violation, so when the migration is
squashed away the stale entry fails instead of rotting into a blind spot.

Adding an entry is not the normal response to a failure. Invert the dependency
instead: expose a hook from `collavre` and let the satellite register itself.

## What this does not do

The ratchet stops *growth*. It does not shrink the 438 entities already in the
baseline, and it can be routed around by adding a hundred small files instead of
one big one. Neither is a gap a PR gate can close.

For that, use the churn×complexity data — files that are both large and
frequently edited — to allocate a refactoring budget each quarter. That belongs
in planning, not in CI: a report that does not block controls nothing, and a
blocking gate cannot make anyone delete code.

## Rejected alternatives

- **A test-to-app LOC ratio floor.** The core already has a healthy 1.51 ratio
  *and* the god objects. Test LOC is trivially gamed with fixture style, mocks,
  and duplicated setup — it is a lagging indicator dressed as a leading one.
- **A core public-API coupling gate.** Real signal, but multiple days of work
  plus ongoing threshold tuning, against a coverage config change that costs
  nothing and lands today.
- **Enforcing "all extension goes through `IntegrationRegistry`".**
  `docs/conventions.md` and `docs/host_architecture.md` both explicitly bless
  satellites injecting associations into core models from an initializer. A test
  contradicting the documented architecture gets deleted, not obeyed. The
  boundary test asserts only the genuinely one-directional half of the rule.
