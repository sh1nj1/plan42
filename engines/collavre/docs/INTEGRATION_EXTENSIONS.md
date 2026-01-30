# Collavre Integration Extensions

This document explains how to create integration extensions for Collavre using the `IntegrationRegistry` system.

## Overview

Collavre provides an extension system that allows external Rails engines to register themselves as integrations. This enables third-party integrations (Slack, GitHub, Notion, etc.) to appear in the Collavre UI without modifying the core collavre engine.

## How It Works

1. External engines register with `Collavre::IntegrationRegistry` during Rails initialization
2. Collavre renders registered integrations dynamically in the UI
3. Each integration provides its own partials for UI components (modals, settings, etc.)

## Registering an Integration

In your engine's `lib/your_engine/engine.rb`, add an initializer to register with Collavre:

```ruby
module YourIntegration
  class Engine < ::Rails::Engine
    isolate_namespace YourIntegration

    # Register as Collavre integration
    initializer "your_integration.register_integration", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        if defined?(Collavre::IntegrationRegistry)
          Collavre::IntegrationRegistry.register(:your_integration, {
            label: I18n.t("your_integration.integration.label", default: "Your Integration"),
            icon: "your-icon",
            description: I18n.t("your_integration.integration.description", default: "Description of your integration"),
            routes: YourIntegration::Engine.routes.url_helpers,
            creative_menu_partial: "your_integration/integrations/modal",
            settings_partial: "your_integration/integrations/settings",  # optional
            enabled_for: ->(creative) { creative.present? }  # optional custom check
          })
        end
      end
    end
  end
end
```

## Configuration Options

| Option | Required | Description |
|--------|----------|-------------|
| `label` | Yes | Display name shown in menus (e.g., "Slack", "GitHub") |
| `icon` | No | Icon identifier for the integration |
| `description` | No | Brief description of what the integration does |
| `routes` | No | Engine routes url_helpers for generating URLs in partials |
| `creative_menu_partial` | Yes | Path to the partial rendered in the creative integrations modal area |
| `settings_partial` | No | Path to the partial for integration settings (if applicable) |
| `enabled_for` | No | Lambda/Proc that receives a creative and returns true/false. Default: always enabled |

## Creating Partials

### Modal Partial (required)

Create a partial at the path specified in `creative_menu_partial`. This partial is rendered when users access the integration from the creative menu.

Example: `app/views/your_integration/integrations/_modal.html.erb`

```erb
<div id="your-integration-modal" style="display:none;">
  <div class="popup-box">
    <button type="button" id="close-your-modal" class="popup-close-btn">&times;</button>
    <h2><%= t('your_integration.modal.title') %></h2>

    <%# Access the creative passed to the partial %>
    <p>Configuring integration for: <%= creative.effective_description %></p>

    <%# Use engine routes via the integration object %>
    <a href="<%= integration.routes.some_path %>">Link</a>
  </div>
</div>
```

### Available Variables in Partials

| Variable | Description |
|----------|-------------|
| `creative` | The current creative being configured |
| `integration` | The `Collavre::Integration` instance with access to `routes`, `name`, `label`, etc. |

## UI Integration Points

When registered, your integration appears in:

1. **Desktop integrations menu**: Dropdown menu in the creative actions row
2. **Mobile actions menu**: Mobile popup menu for integrations
3. **Integration modals area**: Your modal partial is rendered in the creative view

## JavaScript Integration

Your integration will have a hidden trigger button created automatically:

```html
<button id="your_integration-integration-btn" data-creative-id="123" style="display:none;"></button>
```

Add JavaScript to handle the button click and show your modal:

```javascript
// In your engine's JavaScript entry point
document.addEventListener('DOMContentLoaded', () => {
  const btn = document.getElementById('your_integration-integration-btn');
  if (btn) {
    btn.addEventListener('click', () => {
      const modal = document.getElementById('your-integration-modal');
      if (modal) modal.style.display = 'flex';
    });
  }
});
```

## Comments Popup Badge

Integrations can add badges to the comments popup header (e.g., showing linked Slack channels). Collavre dispatches custom events when the comments popup opens and closes.

### Events

| Event | Detail Properties | Description |
|-------|-------------------|-------------|
| `comments-popup:opened` | `creativeId`, `badgeContainer` | Fired when comments popup opens |
| `comments-popup:closed` | `badgeContainer` | Fired when comments popup closes |

### Adding a Badge

Listen for the `comments-popup:opened` event and dynamically create your badge element:

```javascript
// In your engine's JavaScript
document.addEventListener('comments-popup:opened', async function (event) {
  const { creativeId, badgeContainer } = event.detail;
  if (!badgeContainer || !creativeId) return;

  // Create or find your badge element
  let badge = badgeContainer.querySelector('[data-your-integration-badge]');
  if (!badge) {
    badge = document.createElement('span');
    badge.setAttribute('data-your-integration-badge', '');
    badge.className = 'your-integration-badge';
    badge.style.cssText = 'display:none;font-size:0.75em;background:#4A154B;color:white;padding:0.15em 0.5em;border-radius:4px;margin-left:0.5em;';
    badgeContainer.appendChild(badge);
  }

  // Hide initially while loading
  badge.style.display = 'none';
  badge.textContent = '';

  try {
    // Fetch your integration data
    const response = await fetch(`/your-integration/creatives/${creativeId}/status`, {
      headers: { Accept: 'application/json' }
    });
    if (!response.ok) return;

    const data = await response.json();
    if (data.connected) {
      badge.textContent = 'Your Integration: Connected';
      badge.style.display = 'inline-block';
    }
  } catch (error) {
    console.warn('Failed to load badge:', error);
  }
});

document.addEventListener('comments-popup:closed', function (event) {
  const { badgeContainer } = event.detail;
  if (!badgeContainer) return;

  const badge = badgeContainer.querySelector('[data-your-integration-badge]');
  if (badge) {
    badge.style.display = 'none';
    badge.textContent = '';
  }
});
```

### Badge Container

The `badgeContainer` is a `<span data-integration-badges>` element in the comments popup header. Multiple integrations can add their badges to this container.

## i18n Support

Add locale files to your engine:

```yaml
# config/locales/en.yml
en:
  your_integration:
    integration:
      label: "Your Integration"
      description: "Description of your integration"
    modal:
      title: "Configure Your Integration"
```

Ensure your engine loads locale files in `engine.rb`:

```ruby
config.i18n.load_path += Dir[root.join("config", "locales", "*.yml")]
```

## Example: collavre_slack

See `engines/collavre_slack` for a complete example implementation:

- `lib/collavre_slack/engine.rb` - Registration with IntegrationRegistry
- `app/views/collavre_slack/integrations/_modal.html.erb` - Modal partial
- `app/javascript/collavre_slack.js` - JavaScript for modal handling and comments popup badge
- `config/locales/en.yml` - i18n strings (English)
- `config/locales/ko.yml` - i18n strings (Korean)

## Testing

To verify your integration is registered:

```ruby
# In Rails console
Collavre::IntegrationRegistry.all
# => [#<Collavre::Integration name=:your_integration ...>]

Collavre::IntegrationRegistry.find(:your_integration)
# => #<Collavre::Integration ...>
```

## Unregistering

Integrations can be unregistered if needed:

```ruby
Collavre::IntegrationRegistry.unregister(:your_integration)
```

This is typically used in tests or when dynamically managing integrations.
