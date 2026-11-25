# Retired integrations

The Notion and Linear engines have been removed. Their UI registrations, OAuth
callbacks, synchronization jobs, webhook routes, JavaScript bundles, and
integration settings are no longer loaded. GitHub and Slack remain supported.

Existing integration tables and stored settings are retained; this change does
not delete exported Notion pages or Linear issues. Stop or drain integration
jobs before deploying, since their job classes no longer exist. Remove external
Linear webhook subscriptions and revoke unused OAuth credentials separately.

Run `bin/rails db:migrate` during deployment. The host migration removes foreign
keys from retained integration tables to users and creatives, so retired data
cannot block core record deletion after the engine callbacks are removed.
Internal integration foreign keys remain. Restoring core foreign keys on rollback
requires reconciling any retained rows whose users or creatives were deleted.

The 14 historical integration migrations retain their versions and contents in
the host `db/migrate` directory. This preserves both fresh migration installs
and upgrades from databases that have not applied every integration migration.
Historical core migrations and release notes remain as deployment history.
