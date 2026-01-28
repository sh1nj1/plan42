# Collavre Gem Installation Guide

This guide explains how to install and configure the Collavre engine in a Rails application.

## Prerequisites

- Ruby 3.2+
- Rails 8.0+
- Node.js 18+ (for JavaScript asset building)
- npm or yarn

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

The install generator sets up JavaScript asset building for jsbundling-rails:

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

  # Or mount at a subpath
  # mount Collavre::Engine => "/collavre", as: "collavre"
end
```

### 4. Run Migrations

```bash
rails db:migrate
```

### 5. Build Assets

```bash
npm run build
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
npm run build
rails db:migrate
```

## Uninstalling

1. Remove from Gemfile
2. Remove mount from routes
3. Remove stylesheet imports
4. Remove Stimulus controller registration
5. Run `rails db:migrate:down` for Collavre migrations (if needed)
