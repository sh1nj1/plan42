# Agent Development Guide
## Build
use ruby version from ~/.ruby-version

## Before pushing code for PR
- run `./bin/rubocop -a` every time you push code for a PR to confirm code style and no offenses.
- run `rails test`
- run `rails test:system`

## AI Development Guidelines
- Document any AI-specific configuration or workflows in `CLAUDE.md` so other agents can collaborate easily.
- Keep instructions focused and scoped to the relevant directories to avoid unintended overrides.
- Prefer additive guidance over destructive changes when updating agent docs.
- When introducing new AI agents or tools, add a brief summary of their responsibilities and required setup steps.
