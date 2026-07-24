# Collavre Developer Documentation

The single knowledge base for building and operating Collavre. Both human
contributors and AI agents use these docs; [`AGENTS.md`](../AGENTS.md) is the
thin agent entry point that indexes into this directory.

## Architecture & Core Concepts

- [host_architecture.md](host_architecture.md) — how the host shell loads
  engines, plus the multi-engine roster, namespacing, and cross-engine wiring.
- [engines.md](engines.md) — per-engine reference of models, controllers,
  services, and routes.
- [creative_model.md](creative_model.md) — the Creative content unit
  (closure_tree hierarchy, attributes, scopes).
- [permissions.md](permissions.md) — the permission system and the converged
  `CreativeSharesCache` / `PermissionFilter` architecture.

## Building & Contributing

- [conventions.md](conventions.md) — the engineering rulebook: Rails philosophy,
  engine separation, i18n, code quality, env-var propagation, PR/security
  checklists.
- [engine_development.md](engine_development.md) — extend the host with local
  engines and integrate external services (integration-engine pattern).
- [rails8_patterns.md](rails8_patterns.md) — Rails 8 idioms used across the
  codebase (auth, Current, encryption, Hotwire, Solid Queue, Propshaft).
- [testing.md](testing.md) — automated-test conventions.
- [test.md](test.md) — manual QA of the live site (test accounts, credentials).

## Integrations

- [github_integration.md](github_integration.md)
- [notion_integration.md](notion_integration.md)
- [google-auth.md](google-auth.md)
- [mcp-configuration.md](mcp-configuration.md)
- [linked_creative.md](linked_creative.md)

## Operations & Infrastructure

- [deploy_to_lightsail.md](deploy_to_lightsail.md) — single-instance AWS
  Lightsail runbook (host launch script, PostgreSQL, Kamal, backups).
- [deploy_to_ec2.md](deploy_to_ec2.md)
- [github-actions.md](github-actions.md)
- [s3-storage-setup.md](s3-storage-setup.md)
- [fcm-setup.md](fcm-setup.md) · [fcm-local-setup.md](fcm-local-setup.md)
- [async_api_queue.md](async_api_queue.md)
- [dev/](dev/) — deeper design notes (CloudFront assets, encryption key
  rotation, unified filter pipeline).

## Reference

- [dev.md](dev.md) — FAQ and troubleshooting.
- [features_summary.md](features_summary.md)
