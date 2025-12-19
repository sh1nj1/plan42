# Agent Development Guide
## Build
use ruby version from ~/.ruby-version

## Before pushing code for PR
- run `./bin/rubocop -a` every time you push code for a PR to confirm code style and no offenses.
- run `rails test`
- run `rails test:system`
- add original user's requirements to the PR description as `Original User's Requirements` section.

## AI Development Guidelines
- Document any AI-specific configuration or workflows in `CLAUDE.md` so other agents can collaborate easily.
- Keep instructions focused and scoped to the relevant directories to avoid unintended overrides.
- Prefer additive guidance over destructive changes when updating agent docs.
- When introducing new AI agents or tools, add a brief summary of their responsibilities and required setup steps.

## Realtime/WebSocket Conventions
- Use the shared ActionCable consumer from `app/javascript/services/cable.js` to keep a single WebSocket connection.
- Prefer `createSubscription(identifier, callbacks)` for new subscriptions to avoid creating extra consumers.
- Avoid passing arguments to `createConsumer()` after the singleton is initialized; it will be ignored to prevent extra sockets.
- Turbo Streams (inbox items, chat updates, badge counters) should rely on the global `window.ActionCable.createConsumer`
  that is wired to the singleton in `app/javascript/application.js`.
- **CRITICAL**: When using `@hotwired/turbo-rails` with bundlers (esbuild), global `window.ActionCable` patches may be ignored by Turbo.
  You must explicitly inject the consumer into Turbo (e.g., using `setConsumer` imported via deep path if necessary).
