# Retired integrations

The Notion and Linear engines have been removed. Their UI registrations, OAuth
callbacks, synchronization jobs, webhook routes, JavaScript bundles, and
integration settings are no longer loaded. GitHub and Slack remain supported.

Existing integration tables and stored settings are retained; this change does
not delete exported Notion pages or Linear issues. Stop or drain integration
jobs before deploying, since their job classes no longer exist. Remove external
Linear webhook subscriptions and revoke unused OAuth credentials separately.

Historical migrations and release notes remain as deployment history.
