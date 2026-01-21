# Engine Development Guide

This guide explains how to extend `collavre` using **Local Engines**.
All engines live in the `engines/` directory and are automatically loaded by the Host App.

## 1. Creating a New Engine
Run the Rails plugin generator:
```bash
rails plugin new engines/my_custom_feature --mountable --dummy-path=spec/dummy --skip-test-unit
```
*Note: We skip test-unit in favor of Minitest (default) or RSpec if configured.*

## 2. Directory Structure
```text
collavre/
├── engines/
│   └── my_custom_feature/
│       ├── app/
│       │   ├── views/       # Override Host App views here
│       │   ├── javascript/  # JS Entry points
│       │   └── assets/      # CSS/Images
│       ├── config/
│       │   └── locales/     # I18n Overrides (en.yml)
│       └── db/
│           └── migrate/     # Migrations (Auto-loaded)
```

## 3. Customization & Overrides

### Overriding Views
To override a view from the main app, simply create a file with the **same path** in your engine.
*   **Host**: `app/views/layouts/application.html.erb`
*   **Engine**: `engines/my_custom_feature/app/views/layouts/application.html.erb`

Your engine's view will take precedence automatically.

### Overriding Text (I18n)
To override text strings, add them to your engine's `config/locales/*.yml` files.
Engine locales are loaded **after** the host app, so they win.

**Example (`engines/my_custom_feature/config/locales/en.yml`):**
```yaml
en:
  hello: "Hello from Custom Engine!"
```

### Static Files (Public)
Any file in `engines/my_custom_feature/public/` is served at the root URL, overriding the host app's public files.
*   **Engine**: `engines/my_custom_feature/public/favicon.ico`
*   **URL**: `https://app.com/favicon.ico`

### Navigation Menu

Engines can add, modify, or remove navigation menu items using the `Navigation::Registry`.
Create an initializer in your engine: `engines/my_custom_feature/config/initializers/navigation.rb`

#### Adding a Menu Item

```ruby
Rails.application.config.to_prepare do
  Navigation::Registry.instance.register(
    key: :my_feature,                        # Unique identifier (required)
    label: "my_engine.feature",              # I18n key or string (required)
    type: :button,                           # :button, :link, :component, :partial
    path: -> { my_custom_feature.dashboard_path },  # Use Proc for dynamic paths
    priority: 200,                           # Lower = earlier (default: 500)
    section: :main,                          # :main, :search, :user (default: :main)
    requires_auth: true,                     # Show only when authenticated
    requires_user: false,                    # Show only when Current.user exists
    desktop: true,                           # Show in desktop nav
    mobile: true                             # Show in mobile popup
  )
end
```

#### Modifying an Existing Item

```ruby
Rails.application.config.to_prepare do
  # Change the priority of the help button
  Navigation::Registry.instance.modify(:help, priority: 999)

  # Hide an item with custom visibility
  Navigation::Registry.instance.modify(:plans, visible: -> { false })
end
```

#### Removing an Item

```ruby
Rails.application.config.to_prepare do
  Navigation::Registry.instance.unregister(:sign_in)
end
```

#### Adding Child Items (Dropdowns)

```ruby
Rails.application.config.to_prepare do
  # Add a child to the user menu
  Navigation::Registry.instance.add_child(:user_menu, {
    key: :my_settings,
    label: "my_engine.settings",
    type: :button,
    path: -> { my_custom_feature.settings_path },
    priority: 50  # Lower priority = appears earlier in the menu
  })
end
```

#### Navigation Item Types

| Type | Description | Required Options |
|------|-------------|------------------|
| `:button` | Form button (`button_to`) | `path` |
| `:link` | Anchor link (`link_to`) | `path` |
| `:partial` | Renders a partial | `partial` |
| `:component` | Renders a ViewComponent | `component`, `component_args` |

#### Available Sections

| Section | Location |
|---------|----------|
| `:search` | Search area (left side) |
| `:main` | Main navigation bar |
| `:user` | User menu area (right side) |

#### Registration Order

The navigation registry follows this execution order on each reload:

```text
1. reset!              ← Registry is cleared (prepended callback)
2. Host App registers  ← Core menu items (home, plans, inbox, etc.)
3. Engines register    ← Engine menu items (runs after host app)
```

This means engines can safely:
- **Add** new items alongside core items
- **Modify** core items (e.g., change priority, hide items)
- **Remove** core items using `unregister`

**Example: Replace the default help button with a custom one**
```ruby
# engines/my_custom_feature/config/initializers/navigation.rb
Rails.application.config.to_prepare do
  # Remove default help button
  Navigation::Registry.instance.unregister(:help)

  # Add custom help button
  Navigation::Registry.instance.register(
    key: :custom_help,
    label: "my_engine.help",
    type: :partial,
    partial: "my_custom_feature/custom_help_button",
    priority: 170
  )
end
```

## 4. JavaScript & CSS

### JavaScript
We use a shared build system (esbuild) driven by the Host App.
1.  Places your entry file at `engines/my_custom_feature/app/javascript/my_custom_feature.js`.
2.  It will be compiled to `app/assets/builds/my_custom_feature.js`.
3.  Include it in your views: `<%= javascript_include_tag "my_custom_feature" %>`.

**Dependencies:**
You can define dependencies in your engine's `package.json`.
Run `npm install` in the project root to install them.

### CSS
If you have a separate stylesheet:
1.  Create `engines/my_custom_feature/app/assets/stylesheets/my_custom_feature.css`.
2.  Add it to `config/initializers/assets.rb` in the Host App (ask a core dev if needed, or update if you have access).

## 5. Testing

### Ruby Tests
*   **Run Host Only**: `rails test`
*   **Run Engine Only**: `rails test engines/my_custom_feature`
*   **Run Everything**: `rake test`

### JS Tests (Jest)
*   **Run Everything**: `npm test`
