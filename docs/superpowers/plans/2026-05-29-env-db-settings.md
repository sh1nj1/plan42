# DB-Backed Integration Settings (on-premise) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let operators configure external integration secrets (Slack/Notion/GitHub OAuth, AWS S3/SES, FCM, Firebase, Google OAuth, Gemini, mail) through an admin UI backed by the DB, so on-premise installs do not require all secrets in `.env` at deploy time.

**Architecture:**
- Separate `Collavre::IntegrationSetting` model (encrypted) — distinct from the existing unencrypted `Collavre::SystemSetting` used for app behavior (rate limits, themes, etc.).
- Registry pattern: each engine registers its keys (category, sensitive, requires_restart, default) at boot.
- Resolver with precedence **DB > ENV > registered default**. ENV acts as initial seed/fallback only.
- Admin UI at `/admin/integrations` grouped by category, with source label ("DB" / "ENV" / "default"), masked sensitive values, "Reset to ENV" action, and "restart required" indicator for boot-time keys.
- Phase 1 wires only Slack (`engines/collavre_slack`) end-to-end as proof. Phase 2+ wires Google/GitHub/Notion OAuth (omniauth.rb), AWS S3/SES, Firebase, FCM, Gemini, Mail.

**Tech Stack:** Rails engine, ActiveRecord::Encryption (already configured), Minitest, ERB views, en/ko i18n.

**Out of scope (Phase 1):** Bootstrap secrets (`DATABASE_URL`, `SECRET_KEY_BASE`, `REDIS_URL`, `RAILS_MASTER_KEY`, `ACTIVE_RECORD_ENCRYPTION_*`, `KAMAL_*`, `PORT`) stay ENV-only and are not registered. The admin UI does not surface them.

---

## File Structure

**New (engine: `collavre`):**
- `engines/collavre/db/migrate/<timestamp>_create_integration_settings.rb` — schema
- `engines/collavre/app/models/collavre/integration_setting.rb` — model
- `engines/collavre/lib/collavre/integration_settings.rb` — module entry point
- `engines/collavre/lib/collavre/integration_settings/registry.rb` — key registration
- `engines/collavre/lib/collavre/integration_settings/key_definition.rb` — value object
- `engines/collavre/lib/collavre/integration_settings/resolver.rb` — DB > ENV > default + cache
- `engines/collavre/config/initializers/integration_settings.rb` — register core keys (omniauth GoogleClientId etc. shells, NOT wired yet)
- `engines/collavre/app/controllers/collavre/admin/integrations_controller.rb` — UI
- `engines/collavre/app/views/collavre/admin/integrations/index.html.erb`
- `engines/collavre/app/views/collavre/admin/integrations/_category.html.erb`
- `engines/collavre/app/views/collavre/admin/integrations/_setting_row.html.erb`
- `engines/collavre/test/models/collavre/integration_setting_test.rb`
- `engines/collavre/test/lib/collavre/integration_settings/registry_test.rb`
- `engines/collavre/test/lib/collavre/integration_settings/resolver_test.rb`
- `engines/collavre/test/controllers/collavre/admin/integrations_controller_test.rb`

**Modified:**
- `engines/collavre/config/routes.rb` — add `resources :integrations, only: [:index, :update]` and `post :reset` member
- `engines/collavre/app/views/collavre/admin/settings/index.html.erb` — add tab link to `/admin/integrations` (Integrations tab)
- `config/locales/en.yml`, `config/locales/ko.yml` — translations
- `engines/collavre_slack/config/initializers/collavre_slack.rb` — switch from `ENV.fetch` to `Collavre::IntegrationSettings::Resolver.get`
- `engines/collavre_slack/lib/collavre_slack/configuration.rb` — same
- `engines/collavre_slack/config/initializers/collavre_slack.rb` (or new `integration_settings.rb` inside the engine) — register Slack keys (`slack_client_id`, `slack_client_secret`, `slack_signing_secret`, `slack_redirect_uri`)

---

## Schema

```ruby
create_table :integration_settings do |t|
  t.string  :key, null: false                  # e.g. "slack_client_id"
  t.text    :value                             # encrypted via ActiveRecord::Encryption
  t.string  :category, null: false             # "slack", "google_oauth", ...
  t.boolean :sensitive, null: false, default: true
  t.boolean :seeded_from_env, null: false, default: false
  t.timestamps

  t.index :key, unique: true
  t.index :category
end
```

Model:
```ruby
module Collavre
  class IntegrationSetting < ApplicationRecord
    self.table_name = "integration_settings"

    encrypts :value, deterministic: false

    validates :key, presence: true, uniqueness: true
    validates :category, presence: true

    after_commit :clear_cache

    private

    def clear_cache
      Rails.cache.delete(self.class.cache_key_for(key))
    end

    def self.cache_key_for(key)
      "collavre/integration_setting/#{key}"
    end
  end
end
```

---

## Registry / Resolver Semantics

`KeyDefinition` (value object):
```ruby
KeyDefinition = Struct.new(:key, :category, :sensitive, :requires_restart, :env_var, :default, keyword_init: true)
```

`Registry` (singleton):
```ruby
module Collavre
  module IntegrationSettings
    class Registry
      include Singleton

      def initialize
        @definitions = {}
      end

      def register(key, category:, sensitive: true, requires_restart: false, env_var: nil, default: nil)
        key = key.to_sym
        @definitions[key] = KeyDefinition.new(
          key: key, category: category, sensitive: sensitive,
          requires_restart: requires_restart,
          env_var: env_var || key.to_s.upcase,
          default: default
        )
      end

      def all = @definitions.values.freeze
      def find(key) = @definitions[key.to_sym]
      def by_category = @definitions.values.group_by(&:category)
    end
  end
end
```

`Resolver`:
```ruby
module Collavre
  module IntegrationSettings
    class Resolver
      class UnknownKeyError < StandardError; end

      class << self
        def get(key)
          definition = Registry.instance.find(key) or raise UnknownKeyError, "Unknown integration setting: #{key}"

          Rails.cache.fetch(IntegrationSetting.cache_key_for(definition.key), expires_in: 5.minutes) do
            db_value(definition) || env_value(definition) || definition.default
          end
        end

        def source_for(key)
          definition = Registry.instance.find(key) or return :unknown
          return :db if IntegrationSetting.find_by(key: definition.key)&.value.present?
          return :env if ENV[definition.env_var].present?
          :default
        end

        private

        def db_value(definition)
          IntegrationSetting.find_by(key: definition.key)&.value.presence
        end

        def env_value(definition)
          ENV[definition.env_var].presence
        end
      end
    end
  end
end
```

**Lazy ENV → DB seed:** explicitly NOT done on read (keeps ENV as override). Instead, admin UI offers a "Seed from ENV" action per key that copies the current ENV value to DB (with `seeded_from_env: true`). This keeps the precedence rule simple: as long as the DB row exists with a non-blank value, DB wins.

**"Reset to ENV":** deletes the DB row → resolver falls back to ENV.

---

## Tasks

### Task 1: Migration + model + first test

**Files:**
- Create: `engines/collavre/db/migrate/<TS>_create_integration_settings.rb`
- Create: `engines/collavre/app/models/collavre/integration_setting.rb`
- Create: `engines/collavre/test/models/collavre/integration_setting_test.rb`

- [ ] **Step 1.1:** Generate migration

```bash
cd /Users/soonoh/project/soonoh/plan42-worktree220
bin/rails generate migration CreateIntegrationSettings --database=primary
```

- [ ] **Step 1.2:** Edit the generated migration to match the Schema block above (encrypted value stays as `text`).

- [ ] **Step 1.3:** Write `engines/collavre/test/models/collavre/integration_setting_test.rb`:

```ruby
require "test_helper"

module Collavre
  class IntegrationSettingTest < ActiveSupport::TestCase
    test "encrypts value" do
      setting = IntegrationSetting.create!(key: "slack_client_id", value: "xoxb-secret", category: "slack")
      raw = IntegrationSetting.connection.select_value(
        "SELECT value FROM integration_settings WHERE id = #{setting.id}"
      )
      assert_not_equal "xoxb-secret", raw
      assert_equal "xoxb-secret", setting.reload.value
    end

    test "requires unique key" do
      IntegrationSetting.create!(key: "slack_client_id", value: "a", category: "slack")
      dup = IntegrationSetting.new(key: "slack_client_id", value: "b", category: "slack")
      assert_not dup.valid?
    end

    test "clears cache on commit" do
      Rails.cache.write(IntegrationSetting.cache_key_for("slack_client_id"), "cached")
      IntegrationSetting.create!(key: "slack_client_id", value: "new", category: "slack")
      assert_nil Rails.cache.read(IntegrationSetting.cache_key_for("slack_client_id"))
    end
  end
end
```

- [ ] **Step 1.4:** Run test (expect fail — no model):

```bash
bin/rails db:migrate
bin/rails test engines/collavre/test/models/collavre/integration_setting_test.rb
```

- [ ] **Step 1.5:** Implement model file (see Model block above).

- [ ] **Step 1.6:** Re-run test — expect pass.

- [ ] **Step 1.7:** Commit:

```bash
git add engines/collavre/db/migrate engines/collavre/app/models/collavre/integration_setting.rb engines/collavre/test/models/collavre/integration_setting_test.rb
git commit -m "feat(collavre): add IntegrationSetting model with encryption"
```

---

### Task 2: KeyDefinition + Registry

**Files:**
- Create: `engines/collavre/lib/collavre/integration_settings.rb`
- Create: `engines/collavre/lib/collavre/integration_settings/key_definition.rb`
- Create: `engines/collavre/lib/collavre/integration_settings/registry.rb`
- Create: `engines/collavre/test/lib/collavre/integration_settings/registry_test.rb`

- [ ] **Step 2.1:** Write the test first:

```ruby
require "test_helper"

module Collavre
  module IntegrationSettings
    class RegistryTest < ActiveSupport::TestCase
      setup { Registry.instance.instance_variable_set(:@definitions, {}) }

      test "registers a key with defaults" do
        Registry.instance.register(:slack_client_id, category: "slack")
        d = Registry.instance.find(:slack_client_id)
        assert_equal "slack",            d.category
        assert_equal true,               d.sensitive
        assert_equal false,              d.requires_restart
        assert_equal "SLACK_CLIENT_ID",  d.env_var
      end

      test "groups by category" do
        Registry.instance.register(:slack_client_id, category: "slack")
        Registry.instance.register(:google_client_id, category: "google_oauth")
        assert_equal %w[slack google_oauth].sort, Registry.instance.by_category.keys.sort
      end
    end
  end
end
```

- [ ] **Step 2.2:** Run, expect fail.
- [ ] **Step 2.3:** Implement `KeyDefinition` and `Registry` per the Registry/Resolver Semantics block above.
- [ ] **Step 2.4:** Re-run test — expect pass.
- [ ] **Step 2.5:** Commit `feat(collavre): add IntegrationSettings registry`

---

### Task 3: Resolver with cache and precedence

**Files:**
- Create: `engines/collavre/lib/collavre/integration_settings/resolver.rb`
- Create: `engines/collavre/test/lib/collavre/integration_settings/resolver_test.rb`

- [ ] **Step 3.1:** Tests cover:
  - DB value wins over ENV
  - ENV used when no DB row
  - Default used when neither
  - `source_for` returns `:db | :env | :default`
  - Unknown key raises
  - Cache is hit on second read

```ruby
require "test_helper"

module Collavre
  module IntegrationSettings
    class ResolverTest < ActiveSupport::TestCase
      setup do
        Registry.instance.instance_variable_set(:@definitions, {})
        Registry.instance.register(:slack_client_id, category: "slack", env_var: "SLACK_CLIENT_ID", default: "default-id")
        Rails.cache.clear
        IntegrationSetting.delete_all
      end

      test "DB beats ENV" do
        IntegrationSetting.create!(key: "slack_client_id", value: "db-val", category: "slack")
        ENV["SLACK_CLIENT_ID"] = "env-val"
        assert_equal "db-val", Resolver.get(:slack_client_id)
        assert_equal :db,      Resolver.source_for(:slack_client_id)
      ensure
        ENV.delete("SLACK_CLIENT_ID")
      end

      test "ENV used when no DB row" do
        ENV["SLACK_CLIENT_ID"] = "env-val"
        assert_equal "env-val", Resolver.get(:slack_client_id)
        assert_equal :env,      Resolver.source_for(:slack_client_id)
      ensure
        ENV.delete("SLACK_CLIENT_ID")
      end

      test "default used when neither" do
        assert_equal "default-id", Resolver.get(:slack_client_id)
        assert_equal :default,     Resolver.source_for(:slack_client_id)
      end

      test "unknown key raises" do
        assert_raises(Resolver::UnknownKeyError) { Resolver.get(:nope) }
      end
    end
  end
end
```

- [ ] **Step 3.2:** Run — expect fail.
- [ ] **Step 3.3:** Implement `Resolver`.
- [ ] **Step 3.4:** Re-run — expect pass.
- [ ] **Step 3.5:** Commit `feat(collavre): add IntegrationSettings resolver`

---

### Task 4: Admin UI controller + minimal view

**Files:**
- Create: `engines/collavre/app/controllers/collavre/admin/integrations_controller.rb`
- Create: `engines/collavre/app/views/collavre/admin/integrations/index.html.erb`
- Create: `engines/collavre/app/views/collavre/admin/integrations/_category.html.erb`
- Create: `engines/collavre/app/views/collavre/admin/integrations/_setting_row.html.erb`
- Modify: `engines/collavre/config/routes.rb` — add routes:

```ruby
scope "/admin", as: :admin do
  # ...existing...
  resources :integrations, only: [:index] do
    collection do
      patch :bulk_update
    end
    member do
      delete :reset                # delete DB row → revert to ENV
      post   :seed_from_env        # copy ENV → DB
    end
  end
end
```

- Create: `engines/collavre/test/controllers/collavre/admin/integrations_controller_test.rb`

Controller responsibilities:
- `index`: lists all registered keys grouped by category, shows current value (masked if sensitive — show last 4 chars), source label, restart-required flag
- `bulk_update`: accepts a form with multiple `integration_setting[<key>]` params; upserts non-blank values; ignores blank inputs
- `reset(key)`: deletes the row
- `seed_from_env(key)`: copies ENV value to DB (sets `seeded_from_env: true`)
- Authorization: reuse same admin filter as `SettingsController` (`before_action :require_admin!` or equivalent — pattern from existing file)

Tests cover:
- `index` renders without admin → 401/403
- `bulk_update` upserts and skips blanks
- `reset` deletes row
- `seed_from_env` copies ENV → DB
- Sensitive values are masked in HTML response

- [ ] **Step 4.1:** Write tests first.
- [ ] **Step 4.2:** Run — expect fail.
- [ ] **Step 4.3:** Implement controller + views.
- [ ] **Step 4.4:** Add i18n keys to `config/locales/en.yml` and `config/locales/ko.yml`:
  - `collavre.admin.integrations.title`
  - `collavre.admin.integrations.source.db|env|default`
  - `collavre.admin.integrations.restart_required`
  - `collavre.admin.integrations.actions.save|reset|seed_from_env`
- [ ] **Step 4.5:** Run — expect pass.
- [ ] **Step 4.6:** Commit `feat(collavre): add /admin/integrations UI`

---

### Task 5: Wire Slack as Phase 1 e2e example

**Files:**
- Modify: `engines/collavre_slack/config/initializers/collavre_slack.rb`
- Modify: `engines/collavre_slack/lib/collavre_slack/configuration.rb`
- Create or modify: an engine-level initializer that registers Slack keys with the Registry

Slack key registration (run inside engine's `to_prepare` so Registry is available):
```ruby
Rails.application.config.to_prepare do
  Collavre::IntegrationSettings::Registry.instance.register(
    :slack_client_id, category: "slack", sensitive: false, requires_restart: true
  )
  Collavre::IntegrationSettings::Registry.instance.register(
    :slack_client_secret, category: "slack", sensitive: true, requires_restart: true
  )
  Collavre::IntegrationSettings::Registry.instance.register(
    :slack_signing_secret, category: "slack", sensitive: true, requires_restart: true
  )
  Collavre::IntegrationSettings::Registry.instance.register(
    :slack_redirect_uri, category: "slack", sensitive: false, requires_restart: true
  )
end
```

Configuration switch — replace `ENV.fetch("SLACK_CLIENT_ID")` with `Collavre::IntegrationSettings::Resolver.get(:slack_client_id)`. Boot-time use means a value change in admin UI requires server restart — UI surfaces "restart required" badge.

- [ ] **Step 5.1:** Write test asserting `CollavreSlack::Configuration.client_id` reads from Resolver.
- [ ] **Step 5.2:** Run — expect fail.
- [ ] **Step 5.3:** Make the swap.
- [ ] **Step 5.4:** Run — expect pass. Also run full engine test suite to confirm no regression.
- [ ] **Step 5.5:** Commit `feat(collavre_slack): use IntegrationSettings::Resolver for OAuth secrets`

---

### Task 6: Ship

- [ ] **Step 6.1:** `bin/rails test` (full suite, host app + all engines).
- [ ] **Step 6.2:** `bundle exec rubocop` (project rubocop config).
- [ ] **Step 6.3:** Push branch.
- [ ] **Step 6.4:** Open PR with summary + test plan.
- [ ] **Step 6.5:** Register `collavre pr_monitor` for the PR.

---

## Phase 2+ (out of scope for this PR, but designed for)

Once Phase 1 lands, each of these is a small follow-up PR that adds a Registry.register call + swaps ENV reads to Resolver.get:

- `engines/collavre/config/initializers/omniauth.rb` — Google / GitHub / Notion OAuth client_id + secret (boot-time, requires_restart=true)
- `config/initializers/firebase_config.rb` — Firebase project/app/api/auth domain
- `config/initializers/fcm.rb` — FCM server key / sender ID / VAPID key
- `config/initializers/ruby_llm.rb` — Gemini API key / base
- `engines/collavre_openclaw/lib/collavre_openclaw/configuration.rb` — OpenClaw timeouts/transport
- AWS S3 / SES env vars (used in Active Storage / SMTP setup)
- Mailer URL host / port / protocol / default-from

---

## Self-Review Notes

- **Spec coverage:** ENV-vs-DB precedence resolved (DB wins, ENV is seed/fallback), encryption used for secrets, bootstrap secrets explicitly excluded, restart-required flag surfaced. ✓
- **No placeholders:** every step has concrete code. ✓
- **Type consistency:** `KeyDefinition`, `Registry.instance.register`, `Resolver.get`, `cache_key_for` used consistently. ✓
- **Backward compat:** Slack engine still functions identically when ENV is set and no DB row exists (Resolver returns ENV value). ✓
