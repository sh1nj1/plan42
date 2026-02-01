# Rails 8 Patterns in Collavre

## Authentication (built-in)

Rails 8 has built-in authentication. Collavre uses it:

```ruby
# app/models/user.rb (via Collavre::User)
has_secure_password
generates_token_for :password_reset, expires_in: 15.minutes
generates_token_for :email_verification, expires_in: 24.hours
```

## Current Attributes

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :session
  
  def user=(user)
    super
    Time.zone = user&.timezone if user&.timezone.present?
  end
end
```

## Encrypted Attributes

For sensitive data, use `encrypts`:

```ruby
class NotionAccount < ApplicationRecord
  encrypts :token, deterministic: false  # Non-deterministic for security
end
```

Requires `config/credentials.yml.enc` with:
```yaml
active_record_encryption:
  primary_key: ...
  deterministic_key: ...
  key_derivation_salt: ...
```

## Hotwire Integration

### Turbo Frames
```erb
<%= turbo_frame_tag @creative do %>
  <%= render @creative %>
<% end %>
```

### Turbo Streams
```ruby
# Broadcasting updates
Turbo::StreamsChannel.broadcast_update_to(
  creative,
  target: dom_id(creative),
  partial: "creatives/creative",
  locals: { creative: creative }
)
```

### Stimulus
```javascript
// app/javascript/controllers/creative_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["description"]
  
  update() {
    this.descriptionTarget.classList.add("updated")
  }
}
```

## Solid Queue (Background Jobs)

Collavre uses Solid Queue (Rails 8 default):

```ruby
# app/jobs/notion_export_job.rb
class NotionExportJob < ApplicationJob
  queue_as :default
  
  def perform(creative_id)
    creative = Creative.find(creative_id)
    NotionCreativeExporter.new(creative).export
  end
end
```

## ActiveStorage

```ruby
class Creative < ApplicationRecord
  has_many_attached :attachments
end

# Direct uploads enabled
# config/storage.yml configures backends
```

## Propshaft (Asset Pipeline)

Collavre uses Propshaft (Rails 8 default):
- Assets in `app/assets/`
- Engine assets auto-registered
- No compilation step for CSS/JS (handled by esbuild)
