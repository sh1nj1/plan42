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
*   **Run Everything**: `rails test`
*   **Run Engine Only**: `rails test engines/my_custom_feature`

### JS Tests (Jest)
*   **Run Everything**: `npm test`
