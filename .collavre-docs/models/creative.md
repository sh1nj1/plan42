# Creative Model

The Creative is Collavre's core content unit - a hierarchical, permissioned document.

## Hierarchy (closure_tree)

Creatives use `closure_tree` gem for nested hierarchy:

```ruby
class Creative < ApplicationRecord
  has_closure_tree order: 'sort_order', numeric_order: true
  
  # Tree navigation
  creative.parent          # Direct parent
  creative.children        # Direct children
  creative.ancestors       # All parents up to root
  creative.descendants     # All children recursively
  creative.self_and_ancestors
  creative.self_and_descendants
  creative.root?           # Has no parent
  creative.leaf?           # Has no children
end
```

## Key Attributes

```ruby
# Core fields
description: text          # Main content (markdown)
progress: decimal          # 0.0 to 1.0
due_at: datetime          # Optional deadline
user_id: integer          # Creator/owner
origin_id: integer        # Root for permission inheritance

# Computed
effective_origin          # Self if root, else origin
```

## Permission Model

Permissions cascade from root (origin) creative:

```ruby
# Direct permissions
creative.permissions.find_by(user: user)&.level  # :read, :write, :admin

# Effective permission (considers inheritance)
creative.effective_permission_for(user)

# Checks
creative.readable_by?(user)
creative.writable_by?(user)
creative.admin_by?(user)
```

## Rich Text & Attachments

```ruby
creative.description              # Plain markdown text
creative.attachments              # ActiveStorage has_many_attached
creative.cover_image              # First image attachment
```

## Tree Operations

```ruby
# Rebuild closure tree (after bulk imports)
Creative.rebuild!

# Move in tree
creative.update(parent: new_parent)

# Reorder siblings
creative.update(sort_order: 2)
```

## Scopes

```ruby
Creative.roots                    # All root creatives
Creative.for_user(user)           # Readable by user
Creative.with_descendants         # Eager load descendants
```
