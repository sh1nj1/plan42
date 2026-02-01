# Permission System

## Permission Levels

Three levels, hierarchical:
- `:read` - View content
- `:write` - Edit content (includes read)
- `:admin` - Manage permissions (includes write)

## Permission Model

```ruby
class Permission < ApplicationRecord
  belongs_to :user
  belongs_to :creative
  
  enum :level, { read: 0, write: 1, admin: 2 }
end
```

## Inheritance

Permissions inherit from the **origin** (root) creative:

```ruby
# For nested creatives
creative.origin          # The root creative
creative.effective_origin  # Self if root, else origin

# Permission check considers inheritance
creative.readable_by?(user)  # Checks effective_origin's permissions
```

## Controller Authorization

```ruby
class CreativesController < ApplicationController
  before_action :set_creative
  before_action :ensure_read_permission
  before_action :ensure_write_permission, only: [:edit, :update]
  before_action :ensure_admin_permission, only: [:destroy]

  private

  def ensure_read_permission
    return if @creative.readable_by?(Current.user)
    render_forbidden
  end

  def ensure_write_permission
    return if @creative.writable_by?(Current.user)
    render_forbidden
  end

  def ensure_admin_permission
    return if @creative.admin_by?(Current.user)
    render_forbidden
  end
end
```

## Creating Permissions

```ruby
# Grant access
Permission.create!(user: user, creative: root_creative, level: :write)

# Via invitation
Invitation.create!(
  inviter: current_user,
  creative: creative,
  permission: :read
)
```

## Owner Permissions

The creative's owner (`user_id`) always has admin access:

```ruby
def admin_by?(user)
  return true if self.user_id == user.id
  effective_permission_for(user) == :admin
end
```
