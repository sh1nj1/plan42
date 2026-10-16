# Collavre Gem Installation Guide

This guide explains how to install and configure the Collavre engine in a Rails application.

## Prerequisites

- Ruby 3.2+
- Rails 8.0+
- Node.js 18+ (for JavaScript asset building)
- npm or Yarn with a physical `node_modules` directory. Yarn Plug'n'Play (PnP)
  is not supported by the generated build script. For Yarn 2+, configure
  `nodeLinker: node-modules` in `.yarnrc.yml` and run `yarn install` before
  running the generator or building assets.

## Installation

### 1. Add the Gem

Add Collavre to your application's Gemfile:

```ruby
# From RubyGems (when published)
gem "collavre"

# From Git repository
gem "collavre", git: "https://github.com/your-org/collavre", glob: "engines/collavre/*.gemspec"

# From local path (for development)
gem "collavre", path: "../path/to/engines/collavre"
```

Then run:

```bash
bundle install
```

### 2. Run the Install Generator

The install generator sets up JavaScript asset building for jsbundling-rails
and installs the exact PDF.js dependency through Yarn when the host has a
`yarn.lock`, or npm otherwise:

```bash
rails generate collavre:install
```

Options:
- `--replace-build-script` - Replace `script/build.cjs` entirely (recommended for new projects)

### 3. Mount the Engine

Add to your `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount Collavre::Engine => "/", as: "collavre"

  # Or mount at a subpath; delegate the origin-root crawler endpoint:
  # get "/robots.txt", to: redirect("/collavre/robots.txt", status: 302)
  # mount Collavre::Engine => "/collavre", as: "collavre"
end
```

### 4. Run Migrations

```bash
rails db:migrate
```

### 5. Build Assets

Use the package manager selected during installation:

```bash
npm run build
# Yarn hosts (node-modules linker only):
yarn build
```

## Configuration

### JavaScript Assets

The install generator modifies your `script/build.cjs` to automatically discover and include Collavre's JavaScript entry points. It works by:

1. Looking for the gem path via `bundle show collavre`
2. Falling back to `engines/collavre/` for monorepo setups
3. Including all entry points from the gem's `app/javascript/` directory

You can also manually set the gem path:

```bash
COLLAVRE_GEM_PATH=/path/to/gem npm run build
# Yarn hosts:
COLLAVRE_GEM_PATH=/path/to/gem yarn build
```

### Stylesheets

Collavre stylesheets are automatically available via Propshaft. Import them in your `app/assets/stylesheets/application.css`:

```css
@import "collavre/creatives";
@import "collavre/comments_popup";
@import "collavre/dark_mode";
@import "collavre/mention_menu";
@import "collavre/popup";
@import "collavre/slide_view";
@import "collavre/user_menu";
@import "collavre/actiontext";
@import "collavre/attachment_card";
@import "collavre/tables";
@import "collavre/activity_logs";
@import "collavre/print";
```

### Stimulus Controllers

Collavre exports a function to register its Stimulus controllers. In your `app/javascript/application.js`:

```javascript
import { Application } from "@hotwired/stimulus"
import { registerControllers } from "collavre"

const application = Application.start()
registerControllers(application)
```

### ActionCable

Collavre uses ActionCable for real-time features. Ensure your application has ActionCable configured:

```ruby
# config/cable.yml
development:
  adapter: async

production:
  adapter: redis
  url: <%= ENV.fetch("REDIS_URL") { "redis://localhost:6379/1" } %>
```

## Rake Tasks

Collavre provides these rake tasks:

```bash
# Print the gem path (useful for debugging)
rails collavre:gem_path

# Build JavaScript with Collavre assets
rails collavre:build_js
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `COLLAVRE_GEM_PATH` | Override automatic gem path detection for builds |

## Troubleshooting

### JavaScript not loading

1. Verify the gem is installed: `bundle show collavre`
2. Check build output for Collavre entries: `npm run build`
3. Ensure `collavre.js` is in your asset precompile list

### Stylesheets not found

1. Verify Propshaft is configured
2. Check that engine's stylesheet path is in asset paths:
   ```ruby
   Rails.application.config.assets.paths
   ```

### Missing routes

Ensure the engine is mounted in your routes and restart the Rails server.

## Updating

When updating the Collavre gem:

```bash
bundle update collavre
bundle exec rails generate collavre:install
npm run build # Use yarn build for Yarn hosts (node-modules linker only).
rails db:migrate
```

Rerunning `collavre:install` is required before building assets, including for
hosts that already have Collavre configured. It installs `pdfjs-dist` at the
exact Node.js 18-compatible version `4.8.69` and updates `script/build.cjs` so
gem entry points can resolve dependencies from the host's `node_modules`.
`bundle update` alone does not install JavaScript dependencies.

For Yarn 2+ hosts, ensure `.yarnrc.yml` sets `nodeLinker: node-modules` and run
`yarn install` before this sequence. PnP is not supported: the generated build
resolves dependencies from the host's physical `node_modules` directory.
Use `yarn build` throughout for Yarn hosts.

Review and commit the resulting `package.json`, `package-lock.json` (or `yarn.lock`), and
`script/build.cjs` changes. Keep the exact PDF.js version pin when updating
dependencies. For a customized build script, merge the generator changes into
your existing configuration; do not use `--replace-build-script` unless you
intend to replace it entirely.

## Uninstalling

1. Remove from Gemfile
2. Remove mount from routes
3. Remove stylesheet imports
4. Remove Stimulus controller registration
5. Run `rails db:migrate:down` for Collavre migrations (if needed)
