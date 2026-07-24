---
name: demo-video
description: Record Collavre demo / feature-intro videos from a declarative YAML scenario. Drives a local dev server with Playwright, animates the REAL AI streaming UI via a local fake OpenAI server, and post-processes to MP4 + poster per theme/size. Use when creating or updating product demo videos, feature walkthroughs, or landing-page clips.
---

# demo-video

Record polished Collavre demo and feature-introduction videos from a **declarative
YAML scenario**. One command seeds demo data, drives a local dev server with
Playwright, and produces an MP4 + poster for each theme and size.

The defining feature: AI agent responses are **real**. A local fake OpenAI-compatible
server streams scripted answers, and Vrex (the demo AI teammate) is configured as an
`openai`-vendor agent pointed at it. So a genuine `@Vrex:` mention drives Collavre's
**actual streaming pipeline** — the video shows the real typing indicator and
token-by-token stream, not a static post-hoc insert.

## Quick start

```bash
# Landing scenario, light + dark, dev server on :53000
skills/demo-video/run.sh

# One theme, a specific size
skills/demo-video/run.sh landing --theme dark --size wide

# Four takes: {en,ko} x {light,dark}
skills/demo-video/run.sh launch --locale en,ko --theme light,dark

# Reuse an already-running dev server, skip reseeding
skills/demo-video/run.sh landing --base http://localhost:3000 --no-seed
```

Output lands in `skills/demo-video/output/<name>[-<locale>][-dark].mp4` (+ `-poster.jpg`).
The scenario's `default_locale` is the unsuffixed one.

Run it from a shell where **mise is active** — otherwise `bin/rails` picks up the
system Ruby 2.6 and the dev server never boots.

## Architecture (4 decoupled units)

```
scenarios/<name>.yml ──▶ lib/record.mjs ──▶ output/<name>-<theme>.mp4
   declarative steps        Playwright runner        (ffmpeg: speed, scale, crf)
   + scripted ai_turns      (theme/size aware)
        │                        │
        │ injected               │ @Vrex mention triggers the real agent
        ▼                        ▼
   lib/fake_llm.py ◀──────── Collavre streaming pipeline
   OpenAI-compatible SSE      (typing indicator + token stream)

   lib/seed.rb  →  Vrex = openai vendor, gateway_url = fake LLM
   run.sh       →  orchestrates: seed → fake_llm → record → ffmpeg
```

## Scenario format

A scenario is data, not code. Add a feature-intro video = add a new YAML file.

```yaml
name: landing
viewport: landing            # landing | wide | square | portrait
default_locale: ko           # locale used when --locale is omitted
poster_at: 28                # seconds; frame used as the poster. Default 0 —
                             # if the video opens on an empty screen, set this,
                             # or the poster ships as a blank rectangle.
                             # May be a per-locale map: {en: 28, ko: 26}
ai_turns:                    # FIFO; one entry consumed per @mention
  - |
    이번 스프린트 우선순위를 분석해보겠습니다 ...
steps:
  - login: { email: pm@collabre.dev, password: demo1234 }
  - shot: 01-root
  - click_row: 콜라브 v2.0 릴리즈
  - open_chat: 콜라브 v2.0 릴리즈
  - topic: 코드 리뷰
  - mention_ai: { text: "@Vrex: ...", shot: 07-typing }
  - wait_stream: { timeout: 45000 }
  - shot: 09-ai-response
```

### Multi-language scenarios

One scenario, N languages — never one file per language. The step list is a
hard-won pile of selectors, waits and orderings; forking it guarantees the copies
drift until one of them quietly records something untrue.

Put every human-readable string in a `strings:` table and reference it as
`{{key}}` anywhere in the scenario. `--locale` picks the column:

```yaml
default_locale: en
strings:
  project:  { en: "Payments v2", ko: "결제 v2" }
  cap_tree: { en: "Nothing retyped.", ko: "다시 친 건 없습니다." }
steps:
  - click_row: "{{project}}"
  - caption: { text: "{{cap_tree}}", ms: 3200 }
  - click: 'creative-tree-row:has-text("{{project}}") [data-progress-toggle]'
```

Interpolation runs over the *whole* scenario, so it reaches text buried inside
selectors — which a captions-only translation layer could not.

**The table must agree with `seed.rb`.** Scenarios click rows *by their text*, and
`DEMO_LOCALE` decides the language the seed writes its creatives in. A key whose
Korean value does not match what the Korean seed wrote is not a typo — it is a
failed run. Same for content the scenario imports: `launch` uploads
`payments-v2-spec.md` in English and `payments-v2-spec.ko.md` in Korean.

### Step vocabulary

| Step | Argument | Effect |
|------|----------|--------|
| `login` | `{email, password}` | Sign in via `/session/new` |
| `goto` | `<path>` | Navigate to `BASE+path` |
| `wait` | `<ms>` | Pause |
| `shot` | `<name>` | Screenshot into `<name>-shots/` |
| `click` | `<css>` | Click a selector |
| `click_row` | `<text>` | Click a `creative-tree-row` by text |
| `open_chat` | `<row text>` | Open the chat popup for a row |
| `topic` | `<name>` | Switch topic tab in the popup |
| `type` | `{selector, text, delay}` | Type into any field |
| `mention_ai` | `{text, shot?, delay?}` | Type + submit a comment (triggers real agent) |
| `wait_stream` | `{timeout?}` | Wait until the AI reply stops streaming |
| `scroll_bottom` | `{selector?}` | Scroll a list to the bottom (default `#comments-list`) |
| `press` | `<key>` | Press a keyboard key |
| `upload` | `{selector, file}` | `setInputFiles` on a hidden `<input type=file>`; `file` is relative to the scenario |
| `wait_for` | `{selector, text?, state?, timeout?}` | Wait for an element (optionally filtered by text). Throws on timeout |
| `caption` | `{text, ms?, hold?}` | On-screen caption. `hold: true` keeps it up; `caption: null` clears it |
| `highlight` | `{selector, ms?}` | Ring-highlight an element. **Throws if missing** unless `optional: true` |
| `js` | `<code>` | Escape hatch: `page.evaluate(code)` |

`caption` and `highlight` are not decoration. A silent screen recording cannot make
a claim, and the elements worth highlighting are the ones the video exists to show —
so `highlight` fails the run when its target is absent rather than shipping a demo
that quietly fails to demonstrate its own point.

## Scenarios

| Scenario | Locale | Shape |
|----------|--------|-------|
| `landing` | ko | Fully-seeded workspace; the recording tours what already exists |
| `launch` | en | Near-empty workspace; the recording **builds** the tree on camera — markdown import → topic → pinned context inherited at a leaf → real agent reply → progress rollup |
| `interface` | en | **A still, not a film.** A spec whose heading, prose, highlighted code fence and table are each their own block, each with its own progress and thread. The artifact is `shots-*/02-interface.png`, which the landing page ships; run it with `--no-post` and ignore the `.mp4`. |

`run.sh` passes the scenario name to the seed as `DEMO_SCENARIO`, so each scenario
gets exactly the starting state it needs. `launch` deliberately seeds an **empty**
project root: a pre-built tree would prove nothing about the import.

Viewports (`viewport:` in the scenario): `landing` 1280x720, `doc` 1280x1160 (stills —
tall enough to hold a whole document, narrow enough that the max-width-capped app
column fills the frame instead of floating in gutter), `wide`, `square`, `portrait`.

## fake_llm.py

Stdlib-only OpenAI-compatible server.

- `POST /inject {"responses": [...]}` — enqueue scripted turns (FIFO)
- `POST /reset` — clear the queue
- `GET /health` — `{ok, queued}`
- `POST /v1/chat/completions` — pops the next turn, streams it as OpenAI SSE
  (falls back to a default line if the queue is empty, so a run never hangs)

Tunables via env: `FAKE_LLM_PORT`, `FAKE_LLM_TOKEN_DELAY`, `FAKE_LLM_CHUNK`.

## Notes

- Targets a **local** dev server. `run.sh` reuses one if `--base` is reachable,
  otherwise starts `bin/rails server` on `--port` and tears it down afterward.
- Seeding **wipes and recreates** demo data (`user_id > 3`). Use `--no-seed` to
  record against existing data.
- Output videos are not committed (`output/` is gitignored). Upload separately
  when wiring into the landing page.
- Requires `python3`, `node`, `ffmpeg`, and Playwright's Chromium (shared global
  cache is fine; `run.sh` runs `npm install` in the skill dir on first use).
