# Host Application Architecture

This document describes the architectural patterns used in the host application (`collavre`) to support on-premise separation.

## 1. Engine Integration
The host application is designed to be a "shell" that loads core features and optionally loads custom "on-premise" modules as Rails Engines.

### Dynamic Loading
- **Gemfile**: Automatically iterates over the `engines/` directory and loads any local engines found there.
- **Initializer**: `config/initializers/local_engines.rb` configures these engines to:
  - Override host views (Prepend view paths).
  - Add migrations to the main schema.
  - Load I18n locales.
  - overriding static assets (favicons, logos).

## 2. Shared Considerations

### Database
- All engines share the **same database** as the host.
- Engine migrations are run via standard `rails db:migrate`.
- Namespacing tables (e.g., `example_custom_projects`) is strictly recommended for engine-specific data to avoid collisions.

### Assets & Javascript
- **Esbuild**: The build script (`script/build.cjs`) automatically discovers and compiles entry points from `engines/*/app/javascript/*.*`.
- **CSS**: Engines should expose their own CSS files if needed, or override partials that include CSS classes.

### Testing
- **Unified Testing**:
  - `rake test`: Runs tests for both the host application and all engines.
  - `rails test`: Runs host application tests only.
  - `rails test engines/`: Runs tests for all engines.
  - `npm test`: Runs Jest tests for both host and engines (configured in `jest.config.cjs`).

## 3. Best Practices for Host Development
- **Partials**: Extracted common UI elements (like `shared/footer`, `shared/navbar`) into partials to make them easily overridable by engines.
- **I18n**: Use `t('app.key')` helper everywhere. Do not hardcode strings. This allows engines to change terminology (e.g., "Plan" vs "Project").
- **Helpers**: Use `method_defined?` checks if calling engine-specific helpers or use a hook pattern.
