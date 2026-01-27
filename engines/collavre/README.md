# Collavre

Collavre is a Rails engine that provides knowledge management, task management, and real-time collaboration features for Rails 8+ applications.

## Features

- **Creatives**: Hierarchical tree-structured items for documentation, tasks, and discussions
- **Real-time Comments**: WebSocket-powered chat with mentions, reactions, and file attachments
- **Permissions**: Fine-grained access control with hierarchical permission inheritance
- **AI Integration**: LLM-powered agents with customizable system prompts
- **Inbox**: Notification system for mentions and updates
- **Themes**: Customizable user themes with dark mode support

## Installation

Add this line to your application's Gemfile:

```ruby
gem "collavre", path: "engines/collavre"
# Or from a git repository:
# gem "collavre", git: "https://github.com/your-org/collavre.git"
```

Then execute:

```bash
$ bundle install
```

## Setup

### 1. Mount the Engine

Add to your `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount Collavre::Engine => "/"

  # Your other routes...
end
```

### 2. Run Migrations

Copy and run the engine migrations:

```bash
$ bin/rails collavre:install:migrations
$ bin/rails db:migrate
```

Or, if the engine is in your repository, migrations are automatically available.

### 3. Configure the Engine (Optional)

Create an initializer at `config/initializers/collavre.rb`:

```ruby
Collavre.configure do |config|
  # User class name (default: "User")
  config.user_class_name = "User"

  # Method to get current user (default: -> { Current.user })
  config.current_user_method = -> { Current.user }
end
```

### 4. Set Up Model Aliases (Optional)

If you want to use models without the `Collavre::` prefix, add to an initializer:

```ruby
Rails.application.config.to_prepare do
  ::User = Collavre::User unless Object.const_defined?(:User)
  ::Creative = Collavre::Creative unless Object.const_defined?(:Creative)
  ::Comment = Collavre::Comment unless Object.const_defined?(:Comment)
  # ... add other models as needed
end
```

### 5. Include Stylesheets

Add to your application layout:

```erb
<%= stylesheet_link_tag "collavre/creatives" %>
<%= stylesheet_link_tag "collavre/actiontext" %>
<%= stylesheet_link_tag "collavre/activity_logs" %>
<%= stylesheet_link_tag "collavre/comments_popup" %>
<%= stylesheet_link_tag "collavre/dark_mode" %>
<%= stylesheet_link_tag "collavre/mention_menu" %>
<%= stylesheet_link_tag "collavre/popup" %>
<%= stylesheet_link_tag "collavre/user_menu" %>
<%= stylesheet_link_tag "collavre/print", media: 'print' %>
```

### 6. Include JavaScript

The engine provides JavaScript modules that integrate with your application's build system. Import in your `application.js`:

```javascript
import "collavre"
```

## Optional Features

### Push Notifications

Add to your Gemfile:

```ruby
gem "fcm"
gem "google-apis-fcm_v1"
```

Configure Firebase in `config/initializers/firebase.rb`.

### Google Calendar Integration

Add to your Gemfile:

```ruby
gem "google-apis-calendar_v3"
gem "googleauth"
```

### GitHub Integration

Add to your Gemfile:

```ruby
gem "octokit"
```

### PPT/PPTX Import

Add to your Gemfile:

```ruby
gem "rubyzip"
```

## Core Models

| Model | Description |
|-------|-------------|
| `Collavre::User` | User accounts with optional AI agent capabilities |
| `Collavre::Creative` | Hierarchical tree items (docs, tasks, discussions) |
| `Collavre::Comment` | Real-time chat messages within creatives |
| `Collavre::Topic` | Conversation namespaces within creatives |
| `Collavre::CreativeShare` | Permission grants for sharing creatives |
| `Collavre::InboxItem` | User notifications |

## Permissions

Collavre uses a hierarchical permission system:

- `no_access` - No access to the creative
- `read` - View only
- `feedback` - Can add comments
- `write` - Can edit content
- `admin` - Full control including sharing

Permissions cascade from parent to children in the creative tree.

```ruby
creative.has_permission?(user, :write)  # Check permission
creative.grant_permission(user, :read)  # Grant permission
```

## AI Agents

Users can be configured as AI agents with custom system prompts:

```ruby
user.update(
  llm_vendor: "google",
  llm_model: "gemini-2.0-flash",
  system_prompt: "You are a helpful assistant..."
)
```

System prompts support Liquid templates with access to context variables.

## Development

### Running Tests

```bash
$ cd engines/collavre
$ bin/rails test
```

### Running from Host App

```bash
$ bin/rails test engines/collavre/test
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
