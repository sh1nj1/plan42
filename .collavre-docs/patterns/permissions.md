# Permission System

## Permission Levels

Five levels, hierarchical (ascending order):
- `:no_access` - Explicitly blocked
- `:read` - View content
- `:feedback` - View and leave comments
- `:write` - Edit content (includes feedback)
- `:admin` - Manage permissions (includes write)

## Permission Model

Permissions are stored as `CreativeShare` records:

```ruby
class CreativeShare < ApplicationRecord
  belongs_to :user, optional: true  # nil = public share
  belongs_to :creative

  enum :permission, { no_access: 0, read: 1, feedback: 2, write: 3, admin: 4 }
end
```

## Inheritance

Permissions inherit from the **origin** (root) creative:

```ruby
# For nested creatives
creative.effective_origin  # Self if root, else origin

# Permission check considers inheritance (uses CreativeSharesCache)
creative.has_permission?(user, :read)   # => true/false
creative.has_permission?(user, :write)
creative.has_permission?(user, :admin)
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
    return if @creative.has_permission?(Current.user, :read)
    render_forbidden
  end

  def ensure_write_permission
    return if @creative.has_permission?(Current.user, :write)
    render_forbidden
  end

  def ensure_admin_permission
    return if @creative.has_permission?(Current.user, :admin)
    render_forbidden
  end
end
```

## Creating Permissions

```ruby
# Grant access
CreativeShare.create!(user: user, creative: root_creative, permission: :write)

# Via invitation
Invitation.create!(
  inviter: current_user,
  creative: creative,
  permission: :read
)
```

## Owner Permissions

The creative's owner (`user_id`) always has admin access. This is enforced in
`Collavre::Creatives::PermissionChecker`, which grants the owner full access
regardless of any `CreativeShare` record.
