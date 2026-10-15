#!/usr/bin/env bash
# Boot a production-like server (desktop env: Solid Queue inside Puma, Solid
# Cache, multi-database SQLite) in an isolated data dir, run the multi-user
# agent load test against it, and stop the server.
#
#   script/perf/run_local.sh                       # 10 users x 4 agents
#   PERF_USERS=5 PERF_LLM_SECONDS=10 script/perf/run_local.sh
#
# Server capacity knobs pass through: RAILS_MAX_THREADS, WEB_CONCURRENCY,
# AI_AGENT_THREADS, JOB_CONCURRENCY, DB_POOL.
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT="${PERF_PORT:-4999}"
DATA_DIR="${PERF_DATA_DIR:-$PWD/tmp/perf/data}"
PID_FILE="$PWD/tmp/pids/perf.pid"
SERVER_LOG="$PWD/log/perf-server.log"
mkdir -p "$DATA_DIR" "$(dirname "$PID_FILE")" "$(dirname "$SERVER_LOG")"

# A stable key per data dir, so encrypted rows from earlier runs stay readable.
[ -f "$DATA_DIR/secret_key_base" ] || openssl rand -hex 64 > "$DATA_DIR/secret_key_base"

export RAILS_ENV=desktop
export COLLAVRE_DATA_DIR="$DATA_DIR"
export SECRET_KEY_BASE="$(cat "$DATA_DIR/secret_key_base")"
export SOLID_QUEUE_IN_PUMA=true
export RAILS_LOG_LEVEL="${RAILS_LOG_LEVEL:-warn}"

# Load the schema instead of replaying migration history: a full replay loads
# models mid-run, before every column they declare exists.
if [ ! -f "$DATA_DIR/desktop-primary.sqlite3" ]; then
  bin/rails db:create >/dev/null
  for db in primary queue cache cable; do
    SCHEMA=db/schema.rb bin/rails "db:schema:load:$db" >/dev/null
  done
fi
bin/rails db:migrate >/dev/null
[ -f public/assets/.manifest.json ] || bin/rails assets:precompile >/dev/null

stop_server() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
}
trap stop_server EXIT

bin/rails server -p "$PORT" -b 127.0.0.1 -P "$PID_FILE" >"$SERVER_LOG" 2>&1 &

for _ in $(seq 1 60); do
  curl -fs "http://127.0.0.1:$PORT/up" >/dev/null 2>&1 && break
  sleep 1
done
curl -fs "http://127.0.0.1:$PORT/up" >/dev/null || { echo "server did not boot; see $SERVER_LOG"; exit 1; }

PERF_BASE_URL="http://127.0.0.1:$PORT" bin/rails runner script/perf/multi_user_agents.rb
