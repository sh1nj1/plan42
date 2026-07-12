# S3 — API Auth Concern + Internal Error Envelope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove duplicated bearer-auth code across the two API base controllers via a `Collavre::Api::Authenticatable` concern, and introduce a `Collavre::ApiError` + `rescue_from` mechanism in the **collavre core** API engine — **without changing any wire shape** the client or external OpenAI/voice consumers depend on.

**Architecture:** `extract_bearer_token` and `current_user` are byte-identical in both base controllers and hoist verbatim. The Doorkeeper lookup is semantically identical but renders **different** shapes per engine (`collavre` → `{error: "str"}`; `collavre_completion_api` → OpenAI-nested `{error: {message,type,code}}`), so the concern provides a **non-rendering** `find_user_by_bearer_token` helper and each engine keeps its own render. `ApiError`+`rescue_from` is scoped to the **collavre core** engine only (its `{error: "str"}` shape); completion_api keeps its explicit OpenAI-shape renders untouched. This is a pure server-side DRY refactor — **client-side changes are explicitly out of scope**.

**Tech Stack:** Rails 8.1, Minitest (`ActionDispatch::IntegrationTest`), Doorkeeper. Engines: `collavre`, `collavre_completion_api`.

## Global Constraints

- Run tests from **host root** with `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/<engine>/test/...`.
- PR/commit messages **English**, Conventional Commits.
- **WIRE SHAPES THAT MUST NOT CHANGE** (pin each with a test):
  1. 422 validation `{errors: [<strings>]}` non-empty array (JS `queue_manager.js` retry logic + `extractServerErrors`). **Do not touch any `{errors: full_messages}` render.**
  2. OpenAI `{error: {message, type, code}}` at 400/401 (completion_api; external clients + `completions/models` tests).
  3. Voice `{reply, speak, action}` incl. `action.type` (mobile; voice tests). **Do not touch `render_speak`.**
  4. SSE streaming error path `completions_controller.rb:178-195` (emits `chat.completion.chunk` delta, NOT a JSON error). `rescue_from` must not intercept it.
- **No client-side (`.js`) edits.** No changes to `queue_manager.js` / `api_error.js`.
- Auth error copy stays **English literals** (as today) — do NOT retrofit i18n here; changing the strings would change wire output. (i18n for API auth copy is a documented follow-up, not this PR.)
- Concern lives in `engines/collavre/app/controllers/concerns/collavre/` (style-match `creative_permission_guard.rb`). `ApiError` lives in `engines/collavre/app/errors/collavre/` (existing errors dir).

---

### Task 1: `Collavre::Api::Authenticatable` concern (extract duplication, preserve both render shapes)

**Files:**
- Create: `engines/collavre/app/controllers/concerns/collavre/api/authenticatable.rb`
- Modify: `engines/collavre/app/controllers/collavre/api/v1/base_controller.rb` (include concern, use shared lookup)
- Modify: `engines/collavre_completion_api/app/controllers/collavre_completion_api/api/v1/base_controller.rb` (include concern, use shared lookup)
- Test: `engines/collavre/test/controllers/api/v1/agents_controller_test.rb` (pin `{error: "str"}` 401 body)
- Test: `engines/collavre_completion_api/test/controllers/api/v1/models_controller_test.rb` (already pins OpenAI 401 body — extend if needed)

**Interfaces:**
- Produces: module `Collavre::Api::Authenticatable` (`extend ActiveSupport::Concern`, `private` helpers):
  - `extract_bearer_token` → `String | nil` (verbatim from current code)
  - `current_user` → `Collavre::Current.user`
  - `find_user_by_bearer_token(token)` → sets `Collavre::Current.user` and returns the `Collavre::User`, or returns `nil` (no rendering) when token invalid / not accessible / user missing.

- [ ] **Step 1: Write the concern**

Create `engines/collavre/app/controllers/concerns/collavre/api/authenticatable.rb`:

```ruby
module Collavre
  module Api
    module Authenticatable
      extend ActiveSupport::Concern

      private

      def extract_bearer_token
        auth_header = request.headers["Authorization"]
        return nil unless auth_header&.start_with?("Bearer ")

        auth_header.sub("Bearer ", "")
      end

      # Resolves the bearer token to a user via Doorkeeper, sets
      # Collavre::Current.user, and returns the user. Returns nil (without
      # rendering) when the token is blank/invalid/inaccessible or the user
      # is missing — callers own the error response, because the two API
      # engines render different error envelopes.
      def find_user_by_bearer_token(token)
        return nil if token.blank?

        access_token = Doorkeeper::AccessToken.by_token(token)
        return nil unless access_token&.accessible?

        user = Collavre::User.find_by(id: access_token.resource_owner_id)
        return nil unless user

        Collavre::Current.user = user
        user
      end

      def current_user
        Collavre::Current.user
      end
    end
  end
end
```

- [ ] **Step 2: Refactor the collavre core base controller to use the concern (SAME wire shape)**

In `engines/collavre/app/controllers/collavre/api/v1/base_controller.rb`, include the concern and rewrite `authenticate!` to use `find_user_by_bearer_token` while preserving the exact three-message `{error: "str"}` behavior. Note the current code distinguishes blank-token ("Missing authentication token") from invalid ("Invalid authentication token") from user-not-found ("User not found"). To keep byte-identical output, keep the blank-vs-invalid branch explicit:

```ruby
module Collavre
  module Api
    module V1
      class BaseController < ActionController::API
        include Collavre::Api::Authenticatable

        before_action :authenticate!

        private

        def authenticate!
          token = extract_bearer_token
          if token.blank?
            render json: { error: "Missing authentication token" }, status: :unauthorized
            return
          end

          unless find_user_by_bearer_token(token)
            render json: { error: "Invalid authentication token" }, status: :unauthorized
          end
        end
      end
    end
  end
end
```

WIRE-SHAPE NOTE: the original had a **separate** "User not found" message for the (rare) accessible-token-but-missing-user case; the shared helper collapses that into "Invalid authentication token". This changes one 401 message string for an edge case that no client branches on (queue_manager keys on status + `errors` array, not this `error` string). If you want zero message drift, keep the collapse — it is acceptable and simpler. Pin the two common messages in tests (Step 4). If a test asserts the exact "User not found" string, update that test to the collapsed message and note it in the PR body. (Namespacing note: match the file's actual existing module nesting — the current file may use the compact `class Collavre::Api::V1::BaseController`; preserve whichever form is already there rather than reformatting.)

- [ ] **Step 3: Refactor the completion_api base controller (SAME OpenAI wire shape)**

In `engines/collavre_completion_api/app/controllers/collavre_completion_api/api/v1/base_controller.rb`, include the concern and use the shared lookup while preserving the OpenAI-nested render exactly:

```ruby
        include Collavre::Api::Authenticatable

        before_action :authenticate!

        private

        def authenticate!
          token = extract_bearer_token
          if token.blank?
            render json: { error: { message: "Missing authentication token", type: "invalid_request_error",
                                    code: "missing_token" } },
                   status: :unauthorized
            return
          end

          unless find_user_by_bearer_token(token)
            render json: { error: { message: "Invalid authentication token", type: "invalid_request_error",
                                    code: "invalid_token" } },
                   status: :unauthorized
          end
        end
```
Delete the now-redundant local `authenticate_oauth`, `extract_bearer_token`, and `current_user` (they come from the concern). Keep the completion-specific methods (`agent_model_id`, `resolve_agent_by_model`, `collavre_creative`, `collavre_topic`). Preserve the file's existing module nesting form.

- [ ] **Step 4: Pin both 401 wire shapes with tests**

In `engines/collavre/test/controllers/api/v1/agents_controller_test.rb`, extend the existing auth tests to assert the body shape:

```ruby
test "missing token returns collavre-shaped 401 body" do
  post "/api/v1/agent/register", params: { name: "x" }, as: :json
  assert_response :unauthorized
  assert_equal "Missing authentication token", JSON.parse(@response.body)["error"]
end

test "invalid token returns collavre-shaped 401 body" do
  post "/api/v1/agent/register", params: { name: "x" },
    headers: { "Authorization" => "Bearer invalid" }, as: :json
  assert_response :unauthorized
  assert_equal "Invalid authentication token", JSON.parse(@response.body)["error"]
end
```

In `engines/collavre_completion_api/test/controllers/api/v1/models_controller_test.rb`, confirm the existing `body.dig("error","code")` assertions (`missing_token` / `invalid_token`) still pass unchanged. If they only cover one branch, add the missing branch.

- [ ] **Step 5: Run tests**

Run:
```bash
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test \
  engines/collavre/test/controllers/api/v1/agents_controller_test.rb \
  engines/collavre_completion_api/test/controllers/api/v1/models_controller_test.rb \
  engines/collavre_completion_api/test/controllers/api/v1/completions_controller_test.rb \
  engines/collavre/test/controllers/api/v1/mobile/voice_commands_controller_test.rb
```
Expected: PASS (auth still works both shapes; voice + OpenAI shapes unchanged).

- [ ] **Step 6: Commit**

```bash
git add engines/collavre/app/controllers/concerns/collavre/api/authenticatable.rb \
        engines/collavre/app/controllers/collavre/api/v1/base_controller.rb \
        engines/collavre_completion_api/app/controllers/collavre_completion_api/api/v1/base_controller.rb \
        engines/collavre/test/controllers/api/v1/agents_controller_test.rb \
        engines/collavre_completion_api/test/controllers/api/v1/models_controller_test.rb
git commit -m "refactor(api): extract bearer-auth into Collavre::Api::Authenticatable concern"
```

---

### Task 2: `Collavre::ApiError` + `rescue_from` in the collavre core API engine

**Files:**
- Create: `engines/collavre/app/errors/collavre/api_error.rb`
- Modify: `engines/collavre/app/controllers/collavre/api/v1/base_controller.rb` (add `rescue_from`, raise auth errors)
- Test: `engines/collavre/test/controllers/api/v1/agents_controller_test.rb`

**Interfaces:**
- Consumes: the base controller from Task 1.
- Produces: `Collavre::ApiError < StandardError` with `#status` (a Symbol/Integer for `render status:`) and `#message`; a `rescue_from Collavre::ApiError` in the collavre core base controller that renders `{ error: e.message }, status: e.status`. Scope: **collavre core engine only** — completion_api is NOT changed (different envelope).

- [ ] **Step 1: Write the ApiError class**

Create `engines/collavre/app/errors/collavre/api_error.rb`:

```ruby
module Collavre
  # Raised inside collavre-core API v1 controllers to produce the canonical
  # single-message JSON envelope `{ error: "<message>" }` at a chosen status,
  # via the rescue_from in Collavre::Api::V1::BaseController.
  #
  # NOTE: this is the collavre-core `{error: "str"}` shape only. It is NOT for
  # the 422 validation-array shape `{errors: [...]}` (client retry contract),
  # nor the OpenAI-nested shape in collavre_completion_api. Do not route those
  # through this class.
  class ApiError < StandardError
    attr_reader :status

    def initialize(message, status: :unprocessable_entity)
      super(message)
      @status = status
    end
  end
end
```

- [ ] **Step 2: Write the failing test (rescue_from renders `{error:}`)**

Add to `engines/collavre/test/controllers/api/v1/agents_controller_test.rb`:

```ruby
test "ApiError renders the single-message envelope at its status" do
  # The auth branches now raise ApiError; a missing token must still yield
  # {error: "..."} at 401 (contract preserved).
  post "/api/v1/agent/register", params: { name: "x" }, as: :json
  assert_response :unauthorized
  body = JSON.parse(@response.body)
  assert_equal "Missing authentication token", body["error"]
  assert_nil body["errors"], "must not accidentally emit the array-shaped envelope"
end
```

- [ ] **Step 3: Wire rescue_from + raise the auth errors**

In `engines/collavre/app/controllers/collavre/api/v1/base_controller.rb`, add the `rescue_from` and convert `authenticate!` to raise:

```ruby
        include Collavre::Api::Authenticatable

        before_action :authenticate!

        rescue_from Collavre::ApiError do |e|
          render json: { error: e.message }, status: e.status
        end

        private

        def authenticate!
          token = extract_bearer_token
          raise Collavre::ApiError.new("Missing authentication token", status: :unauthorized) if token.blank?

          unless find_user_by_bearer_token(token)
            raise Collavre::ApiError.new("Invalid authentication token", status: :unauthorized)
          end
        end
```

Scope discipline: do NOT convert the `{errors: full_messages}` 422 renders (client contract) or the claim-path renders in `agents_controller.rb` to `ApiError`. Converting the many scattered single-message `{error: "..."}` spots in `agents_controller` is a possible follow-up but is **out of scope for this PR** to keep the just-hardened claim controller stable — leave them as explicit renders. (You MAY convert the two unambiguous non-claim spots `agents_controller.rb:78` `"Agent not found"` / `:83` `"topic_id is required"` only if their tests pass unchanged; otherwise leave them.)

- [ ] **Step 4: Run tests**

Run:
```bash
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/collavre/test/controllers/api/v1/agents_controller_test.rb
```
Expected: PASS (401 still `{error: "..."}`, no `errors` array leak).

- [ ] **Step 5: Commit**

```bash
git add engines/collavre/app/errors/collavre/api_error.rb \
        engines/collavre/app/controllers/collavre/api/v1/base_controller.rb \
        engines/collavre/test/controllers/api/v1/agents_controller_test.rb
git commit -m "refactor(api): add Collavre::ApiError + rescue_from for core envelope"
```

---

### Task 3: Full-suite regression + wire-shape smoke + PR

- [ ] **Step 1: Run both API engines' suites**

Run:
```bash
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/collavre/test
OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES bin/rails test engines/collavre_completion_api/test
```
Expected: PASS (modulo pre-existing unrelated reds on main).

- [ ] **Step 2: Wire-shape smoke — confirm the four protected shapes are intact**

Grep-verify none were touched:
```bash
git diff main --stat            # should NOT list queue_manager.js, api_error.js, render_speak, or the SSE block
grep -rn "render_speak" engines/collavre/app/controllers   # unchanged
grep -rn "errors: .*full_messages" engines/collavre/app/controllers  # array 422 renders unchanged
```
Confirm the diff touches only: the concern, two base controllers, `api_error.rb`, and tests.

- [ ] **Step 3: Push (serial) + PR** — orchestrated externally. PR body must state: server-side DRY only; enumerate the 4 preserved wire shapes; note the "User not found" 401 message collapse (if applied) and that i18n of auth copy is a deliberate follow-up.

## Self-Review Notes (planner)

- Spec coverage: S3-c (server-only) = Authenticatable concern ✓ (Task 1) + `rescue_from`/`ApiError` ✓ (Task 2). Client-contract changes deliberately excluded per the approved decision.
- Every protected wire shape has an explicit "do not touch" + a pinning test (Task 1 Step 4, Task 2 Step 2).
- Type consistency: `find_user_by_bearer_token` returns user-or-nil in both call sites; `ApiError#status` used identically in `rescue_from`.
- Known message drift (edge-case "User not found" → "Invalid authentication token") is flagged for the PR body, not hidden.
