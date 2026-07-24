#!/usr/bin/env bash
#
# demo-video — one-command orchestrator.
#
# Seeds demo data, boots the local fake LLM, drives the recorder for each theme,
# and post-processes to .mp4 + poster. Targets a LOCAL dev server.
#
# Usage:
#   ./run.sh [scenario] [--theme light,dark] [--locale en,ko]
#            [--size landing|wide|square|portrait]
#            [--base URL] [--port N] [--llm-port N] [--no-seed] [--no-post]
#            [--speed N] [--out DIR]
#
# Examples:
#   ./run.sh                       # landing scenario, light+dark, server on :53000
#   ./run.sh landing --theme dark
#   ./run.sh launch --locale en,ko # four takes: {en,ko} x {light,dark}
#   ./run.sh landing --base http://localhost:3000 --no-seed
#
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SKILL_DIR/lib"

# Locate the Rails project root (nearest ancestor with bin/rails).
RAILS_ROOT="$SKILL_DIR"
while [[ "$RAILS_ROOT" != "/" && ! -x "$RAILS_ROOT/bin/rails" ]]; do
  RAILS_ROOT="$(dirname "$RAILS_ROOT")"
done

# ── defaults ────────────────────────────────────────────────────────────
SCENARIO_NAME="landing"
THEMES="light,dark"
# Empty means "whatever the scenario declares as default_locale" — seed.rb and
# record.mjs each fall back on their own, so an unset locale reproduces the
# pre-i18n behaviour exactly.
LOCALES=""
SIZE=""
PORT="53000"
BASE=""
LLM_PORT="8730"
DO_SEED=1
NO_POST=""
SPEED="2"
OUT="$SKILL_DIR/output"

# First positional arg (not starting with --) is the scenario name.
if [[ $# -gt 0 && "${1:0:2}" != "--" ]]; then SCENARIO_NAME="$1"; shift; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --theme) THEMES="$2"; shift 2;;
    --locale) LOCALES="$2"; shift 2;;
    --size) SIZE="$2"; shift 2;;
    --base) BASE="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --llm-port) LLM_PORT="$2"; shift 2;;
    --speed) SPEED="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --no-seed) DO_SEED=0; shift;;
    --no-post) NO_POST="--no-post"; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -z "$BASE" ]] && BASE="http://localhost:$PORT"
LLM_URL="http://127.0.0.1:$LLM_PORT"
SCENARIO_FILE="$SKILL_DIR/scenarios/$SCENARIO_NAME.yml"
[[ -f "$SCENARIO_FILE" ]] || { echo "scenario not found: $SCENARIO_FILE" >&2; exit 2; }

echo "demo-video"
echo "  scenario : $SCENARIO_NAME ($SCENARIO_FILE)"
echo "  themes   : $THEMES"
echo "  base     : $BASE"
echo "  llm      : $LLM_URL"
echo "  rails    : $RAILS_ROOT"
echo "  out      : $OUT"

FAKE_PID=""
SERVER_PID=""
cleanup() {
  [[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" 2>/dev/null || true
  if [[ -n "$SERVER_PID" ]]; then
    echo "→ stopping dev server ($SERVER_PID)"
    kill "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── 1. fake LLM ─────────────────────────────────────────────────────────
echo "→ starting fake LLM on :$LLM_PORT"
FAKE_LLM_PORT="$LLM_PORT" python3 "$LIB/fake_llm.py" &
FAKE_PID=$!
for _ in $(seq 1 30); do
  curl -sf "$LLM_URL/health" >/dev/null 2>&1 && break
  sleep 0.3
done
curl -sf "$LLM_URL/health" >/dev/null 2>&1 || { echo "fake LLM failed to start" >&2; exit 1; }

# ── 2. ensure dev server ────────────────────────────────────────────────
if curl -sf "$BASE" >/dev/null 2>&1; then
  echo "→ dev server already up at $BASE"
else
  echo "→ starting dev server on :$PORT"
  # Run the server as the subshell's exec'd image so $! is the Rails/puma PID
  # itself, not a transient wrapper. A backgrounded `cd && nohup … & echo $!`
  # captures the wrapper subshell on bash 3.2 (macOS), so the cleanup trap kills
  # the wrapper and leaks the actual server. `( cd … && exec … ) &` + `$!` binds
  # SERVER_PID to the process the trap must kill.
  # --pid is not optional: Rails defaults every server in a given app dir to the
  # same tmp/pids/server.pid, so booting here while a PR-preview server is up in
  # the same worktree makes Rails print "a server is already running" and exit —
  # and the recording then fails on a dev server that never came up.
  ( cd "$RAILS_ROOT" && exec env PORT="$PORT" bin/rails server -p "$PORT" -b 0.0.0.0 \
      --pid "tmp/pids/demo-video-$PORT.pid" \
      > /tmp/demo-video-server-$PORT.log 2>&1 ) &
  SERVER_PID=$!
  echo "$SERVER_PID" > /tmp/demo-video-server-$PORT.pid
  for _ in $(seq 1 60); do
    curl -sf "$BASE" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -sf "$BASE" >/dev/null 2>&1 || { echo "dev server failed to start (see /tmp/demo-video-server-$PORT.log)" >&2; exit 1; }
fi

# ── 3. node deps ────────────────────────────────────────────────────────
if [[ ! -d "$SKILL_DIR/node_modules/playwright" || ! -d "$SKILL_DIR/node_modules/yaml" ]]; then
  echo "→ installing node deps"
  ( cd "$SKILL_DIR" && npm install --silent --no-audit --no-fund )
fi

# ── 4. seed + record each locale x theme ────────────────────────────────
# Re-seeding per take keeps recordings isolated: each run starts from a clean
# topic so the @Vrex mention streams fresh (no "another task running" state), the
# login user's theme is set to match, and — because Collavre reads its UI locale
# off the user record, not off Accept-Language — so is the login user's locale.
# The seed also writes its content in that locale, which the scenario then clicks
# on by text, so seeding and recording must never disagree about it.
SIZE_ARG=()
[[ -n "$SIZE" ]] && SIZE_ARG=(--size "$SIZE")
IFS=',' read -ra THEME_LIST <<< "$THEMES"
IFS=',' read -ra LOCALE_LIST <<< "$LOCALES"
[[ ${#LOCALE_LIST[@]} -eq 0 ]] && LOCALE_LIST=("")
for locale in "${LOCALE_LIST[@]}"; do
  for theme in "${THEME_LIST[@]}"; do
    take="${locale:+$locale-}$theme"
    # An empty locale must vanish entirely rather than reach the callee as "".
    # `${locale:+DEMO_LOCALE=$locale}` cannot do that job: bash only treats a word
    # as an assignment if it looks like one BEFORE expansion, so the expanded form
    # is run as a command ("DEMO_LOCALE=ko: command not found"). Hence `env`.
    SEED_ENV=(DEMO_LLM_URL="$LLM_URL/v1" DEMO_THEME="$theme" DEMO_SCENARIO="$SCENARIO_NAME")
    LOCALE_ARG=()
    if [[ -n "$locale" ]]; then
      SEED_ENV+=(DEMO_LOCALE="$locale")
      LOCALE_ARG=(--locale "$locale")
    fi

    if [[ "$DO_SEED" == "1" ]]; then
      echo "→ seeding demo data (scenario=$SCENARIO_NAME, locale=${locale:-default}, theme=$theme)"
      ( cd "$RAILS_ROOT" && exec env "${SEED_ENV[@]}" bin/rails runner "$LIB/seed.rb" \
          > /tmp/demo-video-seed-$take.log 2>&1 ) || { echo "seed failed (see /tmp/demo-video-seed-$take.log)"; exit 1; }
    fi
    echo "→ recording locale=${locale:-default} theme=$theme"
    node "$LIB/record.mjs" \
      --scenario "$SCENARIO_FILE" \
      --theme "$theme" \
      ${LOCALE_ARG[@]+"${LOCALE_ARG[@]}"} \
      --base "$BASE" \
      --llm "$LLM_URL" \
      --out "$OUT" \
      --speed "$SPEED" \
      ${SIZE_ARG[@]+"${SIZE_ARG[@]}"} $NO_POST
  done
done

echo "✅ done. Output in: $OUT"
ls -la "$OUT"/*.mp4 2>/dev/null || true
