# Agent Development Guide
## Build
use ruby version from ~/.ruby-version

## Before pushing code for PR
- run `./bin/rubocop -a` every time you push code for a PR to confirm code style and no offenses.
- run `rake test`
- run `rake test:system` for headless chrome test
- add original user's requirements to the PR description as `Original User's Requirements` section.

## Development

- Use css class for CSP protection. Do not use inline style.

## Environment Variables

When adding a new environment variable, it MUST be added to ALL of the following files:

| File | Format | Notes |
|------|--------|-------|
| `.env.*` | `KEY=value` | All env files |
| `.kamal/secrets` | `KEY=${KEY}` | Kamal deployment secrets |
| `config/deploy.yml` | `- KEY` (under `env.secret`) | Kamal deploy config |

If the variable is used in database connections, also update `config/database.yml`.

## Domain Knowledge

- H2, H3 are systems for managing training for medical professionals.
- MIS2 is internal system for managing H2 and H3.
- Multi-database: primary (SQLite/PostgreSQL), H2 (MySQL), H3 (PostgreSQL). See `config/database.yml`.