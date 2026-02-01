# Engine Integration Pattern

## Creating a New Integration Engine

Follow the pattern of `collavre_openclaw` and `collavre_notion`.

### 1. Engine Structure

```
engines/collavre_myengine/
├── app/
│   ├── controllers/collavre_myengine/
│   ├── models/collavre_myengine/
│   ├── services/collavre_myengine/
│   ├── jobs/collavre_myengine/
│   └── views/collavre_myengine/
├── config/
│   ├── routes.rb
│   └── locales/
├── db/migrate/
├── lib/
│   └── collavre_myengine/
│       ├── engine.rb
│       └── version.rb
├── test/
└── collavre_myengine.gemspec
```

### 2. Engine Configuration

```ruby
# lib/collavre_myengine/engine.rb
module CollavreMyengine
  class Engine < ::Rails::Engine
    isolate_namespace CollavreMyengine

    # Mount routes
    initializer "collavre_myengine.routes", before: :add_routing_paths do |app|
      app.routes.append do
        mount CollavreMyengine::Engine => "/myengine", as: :myengine_engine
      end
    end

    # Add migrations
    initializer "collavre_myengine.migrations" do |app|
      config.paths["db/migrate"].expanded.each do |path|
        app.config.paths["db/migrate"] << path
      end
    end

    # Inject associations
    initializer "collavre_myengine.associations", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        Collavre.user_class.has_one :myengine_account,
          class_name: "CollavreMyengine::MyengineAccount",
          dependent: :destroy
      end
    end

    # Register with IntegrationRegistry (optional)
    initializer "collavre_myengine.register", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        if defined?(Collavre::IntegrationRegistry)
          Collavre::IntegrationRegistry.register(:myengine, {
            label: "My Engine",
            icon: "myengine",
            routes: CollavreMyengine::Engine.routes.url_helpers
          })
        end
      end
    end
  end
end
```

### 3. Add to Gemfile

```ruby
# Gemfile
gem "collavre_myengine", path: "engines/collavre_myengine"
```

### 4. Security Patterns

Always encrypt sensitive tokens:
```ruby
class MyengineAccount < ApplicationRecord
  encrypts :api_token, deterministic: false
end
```

For callbacks from external services, use nonce authentication:
```ruby
class CallbacksController < ApplicationController
  skip_before_action :verify_authenticity_token
  
  def create
    return head :unauthorized unless valid_nonce?(params[:nonce])
    # Process callback
  end
end
```

### 5. Test Helpers

In `test/test_helper.rb`:
```ruby
ENV["RAILS_ENV"] ||= "test"
require_relative "../../../test/test_helper"  # Load host app test helper

class ActionDispatch::IntegrationTest
  def myengine
    CollavreMyengine::Engine.routes.url_helpers
  end
end
```
