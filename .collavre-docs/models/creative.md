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
user_id: integer          # Creator/owner
origin_id: integer        # Root for permission inheritance
sequence: integer         # Sort order within siblings
archived_at: datetime     # Set when archived (nil = active)
data: jsonb               # Flexible metadata (e.g. kind: 'inbox')

# Computed
effective_origin          # Self if root, else origin
```

## Permission Model

Permissions are stored as `CreativeShare` records and cascade from the root (origin) creative:

```ruby
# Check permission (uses CreativeSharesCache for fast lookups)
creative.has_permission?(user, :read)   # => true/false
creative.has_permission?(user, :write)
creative.has_permission?(user, :admin)

# Permission levels (in ascending order)
# :no_access, :read, :feedback, :write, :admin
```

## Rich Text & Attachments

```ruby
creative.description              # Plain markdown text
creative.comments                 # Has-many comments (images attached to comments)
```

## Tree Operations

```ruby
# Rebuild closure tree (after bulk imports)
Collavre::Creative.rebuild!

# Move in tree
creative.update(parent: new_parent)

# Reorder siblings
creative.update(sequence: 2)
```

## Scopes

```ruby
Creative.roots                    # All root creatives
Creative.active                   # Not archived (archived_at IS NULL)
Creative.archived                 # Archived (archived_at IS NOT NULL)
Creative.inboxes                  # Inbox creatives (data->kind = 'inbox')
```
