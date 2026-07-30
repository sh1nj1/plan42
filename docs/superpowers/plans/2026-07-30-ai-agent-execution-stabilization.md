# AI Agent Execution Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `max_concurrent_jobs=12` actually executable and eliminate zombie worker threads: dedicated `ai_agents` queue with 12 threads, cooperative cancellation that honors externally-failed tasks, and a wall-clock deadline per agent turn.

**Architecture:** Three independent fixes to the AiAgentJob execution path. (1) `AgentLifecycleManager#check_cancelled!` currently only raises on `cancelled`, so a task marked `failed` by StuckDetectorJob keeps its worker thread streaming for the rest of the provider call (observed: 1h+ zombie thread in production, 2026-07-29). Extend it to all terminal statuses. (2) `RubyLLM.config.request_timeout` bounds one HTTP request, but a turn is a loop (LLM → tools → LLM …), so turn wall-clock is unbounded — add a per-turn deadline checked in the same chunk callback. (3) AiAgentJob shares the 3-thread `default` Solid Queue worker with broadcasts/mailers/notifications; long AI turns starve them and cap real AI concurrency at 3 regardless of OrchestratorPolicy. Move it to a dedicated `ai_agents` queue with its own worker.

**Tech Stack:** Rails engines (`collavre` core engine), Solid Queue, RubyLLM, Minitest.

**Background (production evidence, 2026-07-29):** default queue had 233 ready jobs; all 3 default worker threads were claimed by AiAgentJobs; one thread was still streaming for task 15066 an hour after StuckDetectorJob had marked that row `failed`. See `ai_agent_job.rb` ensure-block comment: "StuckDetector failed this row while this worker was still in the provider call."

## Global Constraints

- All work in a new git worktree: `../plan42-worktree{N}` (superpowers:using-git-worktrees).
- Commit messages in English, Conventional Commits (`feat:`, `fix:`, `test:`).
- PR description in English. Squash merge; update local main after merge; delete worktree.
- All user-visible text via i18n, **both `en` and `ko`** locales.
- 100% test coverage for changed lines.
- Run only the tests for changed code locally; push with `--no-verify` (CI runs the full suite).
- Rubocop must pass: `./bin/rubocop -a` before PR.
- Env var additions must be reflected in: `env.template`, `config/deploy.yml` (`.kamal/secrets` only if secret — none here are).
- No host-specific names (e.g. tailnet hostnames) in PR descriptions or comments.
- All commands below run from the worktree root (host app root).

## File Structure

| File | Responsibility |
|---|---|
| `engines/collavre/app/services/collavre/ai_agent/agent_lifecycle_manager.rb` | Cancellation + deadline checks during streaming (Tasks 1, 2) |
| `engines/collavre/app/errors/collavre/turn_deadline_error.rb` (new) | Deadline error type, subclass of `CancelledError` (Task 2) |
| `engines/collavre/app/models/collavre/system_setting.rb` | New `ai_agent_turn_deadline_seconds` setting (Task 2) |
| `engines/collavre/app/controllers/collavre/admin/settings_controller.rb` | Admin UI wiring for the new setting (Task 2) |
| `engines/collavre/app/views/collavre/admin/settings/_system_tab.html.erb` | Admin form field (Task 2) |
| `engines/collavre/config/locales/admin.en.yml`, `admin.ko.yml` | Labels/hints (Task 2) |
| `engines/collavre/app/jobs/collavre/ai_agent_job.rb` | `queue_as :ai_agents` (Task 3) |
| `config/queue.yml` | Dedicated `ai_agents` worker (Task 3) |
| `config/database.yml` | Connection pool sized for the new worker threads (Task 3) |
| `config/deploy.yml`, `env.template` | `AI_AGENT_THREADS` documentation (Task 3) |

**Design constraint that shapes Task 2:** `AiClient#chat` has `rescue CancelledError; raise` but `rescue StandardError` swallows everything else into a "⚠️ AI Error" yield (`ai_client.rb:168-192`). Any error raised from the chunk callback that must abort the turn **must be a `CancelledError` (or subclass)** or it will be silently eaten. This is why `TurnDeadlineError < CancelledError`.

---

### Task 1: Cooperative cancellation honors externally-failed tasks

**Files:**
- Modify: `engines/collavre/app/services/collavre/ai_agent/agent_lifecycle_manager.rb:49-56`
- Test: `engines/collavre/test/services/ai_agent_service_test.rb`

**Interfaces:**
- Consumes: `Collavre::CancelledError` (`engines/collavre/app/errors/collavre/cancelled_error.rb`), `Task#status`.
- Produces: `AgentLifecycleManager::TERMINAL_STATUSES` (`%w[cancelled failed]`, frozen) — Task 2 keeps this check and adds the deadline check after it. Behavior: `check_cancelled!` raises `Collavre::CancelledError` when the reloaded task status is any terminal status, not just `cancelled`.

**Recovery path this reuses (no changes needed):** `AiAgentService#call` rescues `CancelledError` → `handle_cancelled` (keeps partial content or destroys placeholder) → re-raise; `AiAgentJob#perform` rescues `CancelledError` → does NOT overwrite status (so `failed` stays `failed`) → `DeliveryRecord.restore_if_undelivered!` → ensure block releases the ResourceTracker slot and drains the topic queue. The `worker_settling?` branch in the ensure block (`ai_agent_job.rb:293-300`) already handles exactly the StuckDetector race this test simulates.

- [ ] **Step 1: Write the failing test**

Add to `engines/collavre/test/services/ai_agent_service_test.rb`, next to the existing `"saves partial content when cancelled"` test (line ~307). It uses the existing `with_immediate_cancel_checks` helper at the bottom of the file:

```ruby
  # StuckDetectorJob marks a hung task `failed` from another process while
  # this worker is still streaming. The worker must notice at the next chunk
  # and leave through the CancelledError recovery path instead of streaming
  # on — in production a thread kept streaming for an hour after its row was
  # already failed, holding one of the worker's threads the whole time.
  test "stops streaming when the task was failed externally" do
    task_id = @task.id
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &block|
      block.call("Partial ")
      Task.find(task_id).update!(status: "failed")
      block.call("content")
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    with_immediate_cancel_checks do
      assert_raises(Collavre::CancelledError) do
        AiClient.stub :new, mock_client do
          AiAgentService.new(@task).call
        end
      end
    end

    assert_equal "failed", @task.reload.status,
      "the externally-written status must not be overwritten"
    assert @task.task_actions.exists?(action_type: "cancelled")
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test engines/collavre/test/services/ai_agent_service_test.rb -n "/stops streaming when the task was failed externally/"`
Expected: FAIL — `Collavre::CancelledError expected but nothing was raised` (current code only checks `status == "cancelled"`).

- [ ] **Step 3: Implement the terminal-status check**

In `engines/collavre/app/services/collavre/ai_agent/agent_lifecycle_manager.rb`, replace the constants block and `check_cancelled!` (keep `AGENT_STATUS_HEARTBEAT_INTERVAL` as is):

```ruby
      # Minimum interval (in seconds) between cancellation checks to avoid excessive DB queries
      CANCEL_CHECK_INTERVAL = 1.0
      # Interval (in seconds) between agent_status heartbeats during streaming
      AGENT_STATUS_HEARTBEAT_INTERVAL = 3.0
      # Statuses written to the row by another process while this worker is
      # inside the provider call: user Stop -> cancelled, StuckDetectorJob ->
      # failed. Both must stop this worker — a row already settled externally
      # has nobody waiting on this turn, and streaming on holds a worker
      # thread for the rest of the provider call.
      TERMINAL_STATUSES = %w[cancelled failed].freeze
```

```ruby
      # Check if task reached a terminal status, raise Collavre::CancelledError if so
      def check_cancelled!
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if (now - @last_cancel_check_at) < CANCEL_CHECK_INTERVAL

        @last_cancel_check_at = now
        raise Collavre::CancelledError if TERMINAL_STATUSES.include?(@task.reload.status)
      end
```

- [ ] **Step 4: Run the new test and the surrounding suite**

Run: `bin/rails test engines/collavre/test/services/ai_agent_service_test.rb`
Expected: all PASS (the existing cancelled-path tests must not regress).

- [ ] **Step 5: Commit**

```bash
git add engines/collavre/app/services/collavre/ai_agent/agent_lifecycle_manager.rb \
        engines/collavre/test/services/ai_agent_service_test.rb
git commit -m "fix: stop agent streaming when task reaches any terminal status"
```

---

### Task 2: Wall-clock deadline per agent turn

**Files:**
- Create: `engines/collavre/app/errors/collavre/turn_deadline_error.rb`
- Modify: `engines/collavre/app/services/collavre/ai_agent/agent_lifecycle_manager.rb` (initialize + check_cancelled!)
- Modify: `engines/collavre/app/models/collavre/system_setting.rb` (constant near line 43, getter near line 200, `clear_all_cache` list near line 69)
- Modify: `engines/collavre/app/controllers/collavre/admin/settings_controller.rb` (index ~line 26, error re-render ~line 110, `settings_from_params` ~line 133)
- Modify: `engines/collavre/app/views/collavre/admin/settings/_system_tab.html.erb` (after the `llm_request_timeout_seconds` field block, lines 131-137)
- Modify: `engines/collavre/config/locales/admin.en.yml`, `engines/collavre/config/locales/admin.ko.yml` (after `llm_request_timeout_seconds_hint`, line 43)
- Test: `engines/collavre/test/services/ai_agent_service_test.rb`, `engines/collavre/test/models/system_setting_test.rb`, `engines/collavre/test/controllers/admin_settings_controller_test.rb`

**Interfaces:**
- Consumes: `AgentLifecycleManager::TERMINAL_STATUSES` and the `check_cancelled!` structure from Task 1; `SystemSetting.cached_value(key)` (existing).
- Produces:
  - `Collavre::TurnDeadlineError < Collavre::CancelledError` (no methods added).
  - `Collavre::SystemSetting.ai_agent_turn_deadline_seconds` → Integer, default `DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS = 3600`, floor 60 (values `< 60` or unset fall back to default).
  - `check_cancelled!` now also enforces the deadline: marks the task `failed` and raises `Collavre::TurnDeadlineError`.

**Why the deadline check lives in `check_cancelled!`:** it is called from the streaming delta callback (`ai_agent_service.rb:210-216`), the only periodic hook the turn has. Known limitation (accepted): the check fires only when a chunk arrives; a single request that blocks with no chunks is bounded instead by `RubyLLM.config.request_timeout` (Net::HTTP read timeout, default 1800s). What this deadline closes is the unbounded multi-request loop and the slow-trickle stream.

- [ ] **Step 1: Write the failing service test**

Add to `engines/collavre/test/services/ai_agent_service_test.rb`:

```ruby
  # llm_request_timeout_seconds bounds ONE provider request; a turn is a loop
  # of requests (LLM -> tools -> LLM ...), so its wall clock is otherwise
  # unbounded. With the deadline already in the past, the very next chunk
  # must end the turn as failed through the cancellation recovery path.
  test "fails the turn when the wall-clock deadline is exceeded" do
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &block|
      block.call("Partial ")
      block.call("content")
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    with_immediate_cancel_checks do
      Collavre::SystemSetting.stub :ai_agent_turn_deadline_seconds, 0 do
        assert_raises(Collavre::TurnDeadlineError) do
          AiClient.stub :new, mock_client do
            AiAgentService.new(@task).call
          end
        end
      end
    end

    assert_equal "failed", @task.reload.status
    assert @task.task_actions.exists?(action_type: "cancelled")
  end
```

(Note: the raise happens at the first chunk's `check_cancelled!`, before `@streamer.append`, so no partial content exists and `handle_cancelled` destroys the placeholder comment — that's why the test asserts status and the logged action, not comment content.)

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test engines/collavre/test/services/ai_agent_service_test.rb -n "/fails the turn when the wall-clock deadline/"`
Expected: FAIL with `NameError: uninitialized constant Collavre::TurnDeadlineError`.

- [ ] **Step 3: Create the error class**

Create `engines/collavre/app/errors/collavre/turn_deadline_error.rb`:

```ruby
# frozen_string_literal: true

module Collavre
  # Raised by AgentLifecycleManager when an agent turn exceeds its wall-clock
  # deadline (SystemSetting.ai_agent_turn_deadline_seconds).
  #
  # Subclasses CancelledError deliberately: AiClient#chat re-raises
  # CancelledError but swallows every other StandardError into a streamed
  # "AI Error" message, and the CancelledError rescue chain (AiAgentService,
  # AiAgentJob) already preserves partial content, keeps the row's terminal
  # status, releases the resource slot and drains the topic queue.
  class TurnDeadlineError < CancelledError
  end
end
```

- [ ] **Step 4: Add the SystemSetting**

In `engines/collavre/app/models/collavre/system_setting.rb` — three edits:

After `DEFAULT_LLM_REQUEST_TIMEOUT_SECONDS = 1800` (line 43):

```ruby
    # Default wall-clock deadline for one AI agent turn (seconds).
    # A turn is the full LLM -> tools -> LLM loop; llm_request_timeout_seconds
    # bounds only a single request inside it.
    DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS = 3600
```

After the `llm_request_timeout_seconds` getter (line ~200):

```ruby
    # AI agent turn wall-clock deadline (seconds)
    def self.ai_agent_turn_deadline_seconds
      value = cached_value("ai_agent_turn_deadline_seconds")&.to_i
      value.nil? || value < 60 ? DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS : value
    end
```

In `clear_all_cache`, change the last line of the `%w[...]` list (line ~69) from
`display_level completion_mark llm_request_timeout_seconds` to
`display_level completion_mark llm_request_timeout_seconds ai_agent_turn_deadline_seconds`.

- [ ] **Step 5: Wire the deadline into AgentLifecycleManager**

In `engines/collavre/app/services/collavre/ai_agent/agent_lifecycle_manager.rb`:

`initialize` — add one line:

```ruby
      def initialize(task:, agent:, creative:)
        @task = task
        @agent = agent
        @creative = creative
        @last_cancel_check_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_heartbeat_at = @last_cancel_check_at
        @deadline_at = @last_cancel_check_at + SystemSetting.ai_agent_turn_deadline_seconds
      end
```

`check_cancelled!` — full replacement (builds on Task 1's version):

```ruby
      # Check if task reached a terminal status or overran its turn deadline,
      # raise Collavre::CancelledError / Collavre::TurnDeadlineError if so
      def check_cancelled!
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if (now - @last_cancel_check_at) < CANCEL_CHECK_INTERVAL

        @last_cancel_check_at = now
        raise Collavre::CancelledError if TERMINAL_STATUSES.include?(@task.reload.status)

        return if now < @deadline_at

        # This worker is the only process that knows the turn overran, so it
        # writes the terminal status itself before leaving through the
        # cancellation path (which never overwrites a terminal status).
        Rails.logger.warn(
          "[AgentLifecycleManager] Task #{@task.id} exceeded turn deadline " \
          "(#{SystemSetting.ai_agent_turn_deadline_seconds}s); failing"
        )
        @task.update!(status: "failed")
        raise Collavre::TurnDeadlineError
      end
```

- [ ] **Step 6: Run the service test to verify it passes**

Run: `bin/rails test engines/collavre/test/services/ai_agent_service_test.rb`
Expected: all PASS.

- [ ] **Step 7: Write + run the model test**

Add to `engines/collavre/test/models/system_setting_test.rb`:

```ruby
  test "ai_agent_turn_deadline_seconds default, floor, and override" do
    SystemSetting.destroy_all
    Rails.cache.delete("system_setting:ai_agent_turn_deadline_seconds")
    assert_equal SystemSetting::DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS,
                 SystemSetting.ai_agent_turn_deadline_seconds

    setting = SystemSetting.create!(key: "ai_agent_turn_deadline_seconds", value: "10")
    assert_equal SystemSetting::DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS,
                 SystemSetting.ai_agent_turn_deadline_seconds,
                 "below-floor values fall back to the default"

    setting.update!(value: "900")
    assert_equal 900, SystemSetting.ai_agent_turn_deadline_seconds
  end
```

Run: `bin/rails test engines/collavre/test/models/system_setting_test.rb`
Expected: PASS.

- [ ] **Step 8: Admin UI — controller, view, locales**

`engines/collavre/app/controllers/collavre/admin/settings_controller.rb` — three edits, each directly below its `llm_request_timeout_seconds` sibling:

Index action (line ~26):
```ruby
        @ai_agent_turn_deadline_seconds = SystemSetting.ai_agent_turn_deadline_seconds
```

Error re-render (line ~110):
```ruby
        @ai_agent_turn_deadline_seconds = params[:ai_agent_turn_deadline_seconds].to_i.positive? ? params[:ai_agent_turn_deadline_seconds].to_i : SystemSetting::DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS
```

`settings_from_params` (line ~133, add trailing comma to the previous entry):
```ruby
          "ai_agent_turn_deadline_seconds" => int_setting(:ai_agent_turn_deadline_seconds, SystemSetting::DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS, min: 60)
```

`_system_tab.html.erb` — duplicate the `llm_request_timeout_seconds` field block (lines 131-137) directly below it, inside the same section wrapper, swapping names/vars/min:

```erb
      <div>
        <%= f.label :ai_agent_turn_deadline_seconds, t('admin.settings.ai_agent_turn_deadline_seconds') %>
        <%= f.number_field :ai_agent_turn_deadline_seconds, value: @ai_agent_turn_deadline_seconds, min: 60, style: "width: 100%;" %>
        <div class="help-text" style="font-size: 0.85em; color: var(--color-text-muted); margin-top: 0.25em;">
          <%= t('admin.settings.ai_agent_turn_deadline_seconds_hint') %>
        </div>
      </div>
```
(Match the exact wrapper markup of the sibling block — copy it and swap the three names rather than typing fresh markup.)

`admin.en.yml` (after line 43):
```yaml
      ai_agent_turn_deadline_seconds: "Agent Turn Deadline (seconds)"
      ai_agent_turn_deadline_seconds_hint: "Maximum wall-clock time for one AI agent turn, covering all LLM calls and tool runs in the turn. Exceeding it fails the turn; partial replies are kept. Default: 3600 (1 hour). Minimum: 60 seconds."
```

`admin.ko.yml` (after line 43):
```yaml
      ai_agent_turn_deadline_seconds: "에이전트 턴 데드라인 (초)"
      ai_agent_turn_deadline_seconds_hint: "AI 에이전트 턴 1회(턴에 포함된 모든 LLM 호출과 툴 실행)의 최대 실행 시간입니다. 초과 시 턴은 실패 처리되며 부분 응답은 보존됩니다. 기본값: 3600 (1시간). 최소: 60초."
```

- [ ] **Step 9: Write + run the controller test**

Add to `engines/collavre/test/controllers/admin_settings_controller_test.rb` (follows the `password_min_length` clamp tests' idiom):

```ruby
  test "ai_agent_turn_deadline_seconds persists and floors at 60" do
    sign_in_as(@admin, password: "password")

    patch collavre.admin_settings_path, params: { ai_agent_turn_deadline_seconds: 900, auth_providers: [ "email" ] }
    assert_redirected_to collavre.admin_settings_path
    Rails.cache.clear
    assert_equal 900, SystemSetting.ai_agent_turn_deadline_seconds

    patch collavre.admin_settings_path, params: { ai_agent_turn_deadline_seconds: 10, auth_providers: [ "email" ] }
    assert_redirected_to collavre.admin_settings_path
    Rails.cache.clear
    assert_equal SystemSetting::DEFAULT_AI_AGENT_TURN_DEADLINE_SECONDS,
                 SystemSetting.ai_agent_turn_deadline_seconds,
                 "below-floor values fall back to the default"
  end
```

Run: `bin/rails test engines/collavre/test/controllers/admin_settings_controller_test.rb`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add engines/collavre/app/errors/collavre/turn_deadline_error.rb \
        engines/collavre/app/services/collavre/ai_agent/agent_lifecycle_manager.rb \
        engines/collavre/app/models/collavre/system_setting.rb \
        engines/collavre/app/controllers/collavre/admin/settings_controller.rb \
        engines/collavre/app/views/collavre/admin/settings/_system_tab.html.erb \
        engines/collavre/config/locales/admin.en.yml \
        engines/collavre/config/locales/admin.ko.yml \
        engines/collavre/test/services/ai_agent_service_test.rb \
        engines/collavre/test/models/system_setting_test.rb \
        engines/collavre/test/controllers/admin_settings_controller_test.rb
git commit -m "feat: enforce wall-clock deadline per AI agent turn"
```

---

### Task 3: Dedicated `ai_agents` queue and worker

**Files:**
- Modify: `engines/collavre/app/jobs/collavre/ai_agent_job.rb:3`
- Modify: `config/queue.yml`
- Modify: `config/database.yml` (default `pool:` line)
- Modify: `config/deploy.yml` (`clear:` env section, after the `JOB_CONCURRENCY` comment ~line 90)
- Modify: `env.template`
- Test: Create `engines/collavre/test/jobs/collavre/ai_agent_job_queue_test.rb`

**Interfaces:**
- Consumes: nothing from Tasks 1-2 (independent; can land in the same PR).
- Produces: `Collavre::AiAgentJob.new.queue_name == "ai_agents"`; env var `AI_AGENT_THREADS` (default 12) controlling the dedicated worker's thread count; env var `DB_POOL` for explicit pool override.

**Key sizing fact:** an AiAgentJob thread holds one Active Record connection for the whole turn (checked out on first query, returned when the job ends), so 12 concurrent turns hold 12 connections. With `SOLID_QUEUE_IN_PUMA=true` (the default, `config/deploy.yml:87`) all workers run inside the Puma process and share one pool with web threads — the pool must cover web + all worker threads or threads die with `ActiveRecord::ConnectionTimeoutError` after 5s.

- [ ] **Step 1: Write the failing test**

Create `engines/collavre/test/jobs/collavre/ai_agent_job_queue_test.rb`:

```ruby
require "test_helper"

module Collavre
  class AiAgentJobQueueTest < ActiveSupport::TestCase
    # An agent turn runs for minutes; on the 3-thread default worker three
    # turns starve every broadcast, mailer and notification behind them and
    # silently cap real AI concurrency at 3 regardless of
    # OrchestratorPolicy#max_concurrent_jobs. The dedicated queue's worker
    # (config/queue.yml, AI_AGENT_THREADS) is the real execution capacity.
    test "runs on the dedicated ai_agents queue" do
      assert_equal "ai_agents", AiAgentJob.new.queue_name
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test engines/collavre/test/jobs/collavre/ai_agent_job_queue_test.rb`
Expected: FAIL — `Expected: "ai_agents"  Actual: "default"`.

- [ ] **Step 3: Move the job and add the worker**

`engines/collavre/app/jobs/collavre/ai_agent_job.rb` line 3:

```ruby
    queue_as :ai_agents
```

`config/queue.yml` — insert between the default worker block and the `linear_inbound` block:

```yaml
    # Dedicated worker for AI agent turns (AiAgentJob). A turn streams from
    # the LLM for minutes, so these must not share threads with short jobs
    # (broadcasts, mailers, notifications) on the default worker. Thread
    # count is the real execution capacity behind
    # OrchestratorPolicy#max_concurrent_jobs — keep the two in sync.
    # Threads block on provider I/O (GVL released), so they are cheap; each
    # does hold one DB connection for its whole turn — see the pool sizing
    # in config/database.yml.
    - queues: [ai_agents]
      threads: <%= ENV.fetch("AI_AGENT_THREADS", 12) %>
      processes: 1
      polling_interval: 0.1
```

`config/database.yml` — replace the `pool:` line in `default:`:

```yaml
  pool: <%= ENV.fetch("DB_POOL") { ENV.fetch("RAILS_MAX_THREADS") { 5 }.to_i + ENV.fetch("AI_AGENT_THREADS", 12).to_i + 10 } %>
```

(RAILS_MAX_THREADS covers Puma web threads; AI_AGENT_THREADS covers the dedicated worker, each of whose threads holds a connection for the whole turn; +10 covers the remaining in-process Solid Queue threads — authz 2, default 3, linear_inbound 1, dispatcher, recurring scheduler — with margin. `DB_POOL` remains as an explicit override.)

`config/deploy.yml` — in the `clear:` section after the `# JOB_CONCURRENCY: 3` comment (~line 90):

```yaml
    # Threads for the dedicated ai_agents Solid Queue worker (long-running AI
    # agent turns). This is the real execution capacity behind the
    # orchestrator's max_concurrent_jobs — keep the two in sync.
    AI_AGENT_THREADS: <%= ENV.fetch('AI_AGENT_THREADS', '12') %>
```

`env.template` — add alongside the other optional tuning vars:

```bash
# Threads for the dedicated ai_agents Solid Queue worker (default: 12).
# Keep in sync with the orchestrator policy's max_concurrent_jobs.
# AI_AGENT_THREADS=12
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test engines/collavre/test/jobs/collavre/ai_agent_job_queue_test.rb`
Expected: PASS. Also run the existing job suite touched by the queue move:
`bin/rails test engines/collavre/test/jobs/collavre/ai_agent_job_topic_slot_test.rb`
Expected: PASS (ActiveJob tests run inline/test adapter; queue name change must not break them).

- [ ] **Step 5: Boot check**

Run: `bin/rails runner 'puts Rails.application.config_for(:queue).inspect'`
Expected: output includes an entry with `queues: ["ai_agents"], threads: 12` and no YAML/ERB errors.

- [ ] **Step 6: Commit**

```bash
git add engines/collavre/app/jobs/collavre/ai_agent_job.rb \
        engines/collavre/test/jobs/collavre/ai_agent_job_queue_test.rb \
        config/queue.yml config/database.yml config/deploy.yml env.template
git commit -m "feat: run AiAgentJob on dedicated ai_agents queue sized to policy concurrency"
```

---

## Rollout notes (PR description material)

- **In-flight jobs at deploy:** AiAgentJobs already enqueued on `default` before the deploy stay on `default` and are drained by the default worker one last time; new enqueues go to `ai_agents`. No data migration needed.
- **Immediate relief for the current hang:** deploying restarts the app, which clears the existing zombie thread regardless of these fixes.
- **Deploy verification** via `./kamal.sh console`:
  ```ruby
  SolidQueue::Process.where(kind: "Worker").map { |p| p.metadata }
  # expect an entry with "queues"=>["ai_agents"] and 12 threads
  SolidQueue::ReadyExecution.where(queue_name: "default").count   # should drain toward 0
  SolidQueue::ClaimedExecution.count                               # AI turns now claim in ai_agents
  ```

## Out of scope (deliberately deferred)

- **Stream idle watchdog** (close the socket when no chunk arrives for N seconds): the per-request Net::HTTP read timeout (1800s) already bounds a fully-silent read; revisit if silent hangs recur after this PR.
- **Worker-process TERM backstop** for claimed jobs past a hard deadline.
- **Timeouts on individual MCP/tool executions** inside a turn.
- **PushNotificationJob FCM auth failures (1,371 accumulated)** and **StuckDetectorJob failures (343)** — separate investigations.
