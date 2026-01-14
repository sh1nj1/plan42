# Host Architecture: Local Engines

This document explains the architecture supporting On-Premise/Local Engines in `collavre`.

## Core Components

### 1. Auto-Loading (`Gemfile`)
The `Gemfile` is configured to dynamically find and load any gem found in `engines/`.
```ruby
Dir.glob(File.expand_path("engines/*", __dir__)).each do |engine_path|
  gem File.basename(engine_path), path: engine_path
end
```
This means we technically use a "Monorepo" strategy where engines are local path gems.

### 2. The Initializer (`config/initializers/local_engines.rb`)
This file is the specific glue that enables seamless overrides. It iterates over loaded engines and:

1.  **View Precedence**: Calls `prepend_view_path` on `ActionController::Base`. Use `to_prepare` to ensure it works with code reloading.
2.  **Migrations**: Appends `db/migrate` to `config.paths["db/migrate"]`.
3.  **I18n**: Appends locales to `i18n.load_path` (at the end, for precedence).
4.  **Static Files**: Inserts `ActionDispatch::Static` middleware pointing to engine `public/` directories **before** the main app's static middleware.

### 3. JavaScript & Workspaces
*   **Workspaces**: `package.json` defines `workspaces: ["engines/*"]`.
*   **Build**: `esbuild` command includes `engines/*/app/javascript/*.*` as entry points.
*   **Jest**: `jest.config.js` includes `<rootDir>/engines` as a root.

### 4. Docker Deployment
Because `Gemfile` references local paths (`path: "engines/..."`), Bundler requires these files to exist before `bundle install` runs.
The `Dockerfile` has been modified to:
```dockerfile
COPY engines ./engines
RUN bundle install
```
This ensures production builds work correctly.

### 5. CI/CD
*   `rails test` is enhanced in `lib/tasks/engine_tests.rake` to recursively run engine tests.
*   `npm ci` installs workspace dependencies automatically.
