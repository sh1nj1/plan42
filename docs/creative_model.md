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

See [permissions.md](permissions.md) for the full permission architecture.

## Rich Text & Attachments

```ruby
creative.description              # Plain markdown text
creative.comments                 # Has-many comments (images attached to comments)
creative.files                    # Active Storage has_many_attached files
```

Attached `.pptx` files appear at their attachment link position as the same inline
slide viewer in the editor and on the Creative page, including immediately after
upload. The stored description retains the attachment link; both display paths
derive the preview iframe from it. Transparent chevrons sit at the left and right
edges. Desktop hover or keyboard focus reveals controls; clicking a slide opens
native fullscreen. On touch devices, tapping toggles controls and the fullscreen
button opens the presentation. Download is available in both inline and fullscreen
controls, including browsers without native fullscreen; close is fullscreen-only.
Slide hyperlinks open in a new tab instead of replacing the preview.
`Collavre::PptRenderer` renders slide HTML without creating creatives;
`Collavre::PptImporter` reuses it when persisting imported slides.
`Collavre::PptPreview` caches rendered HTML for seven days by blob key and locale.
The preview endpoint checks read permission on the attachment-owning effective
origin on every saved attachment request. Before an upload is attached, only its
uploader can preview it. Responses return `Cache-Control: private, no-store`;
cached rendering never bypasses authorization.
Preview images are embedded in the rendered HTML rather than uploaded as new blobs.
Each image occurrence consumes the cumulative rendered-byte budget before Base64
expansion; encoded data URIs are reused for repeated archive entries.

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

## Linking Creatives through MCP

Discover the following tools with `meta_tool`:

- `creative_link_service(parent_id:, creative_ids:)` links source IDs beneath a
  destination. Sources require read access; the destination requires write access.
  Source and destination links resolve to their effective origins. New shells are
  appended in input order. Existing links to the same origin retain their positions.
- `creative_unlink_service(linked_creative_ids:)` removes only linked shells using
  the same removal permissions and callbacks as the UI. Ordinary Creative IDs are
  rejected; origins, their children and other links remain intact.

Both tools accept nonempty arrays of unique positive integer IDs and apply each
list atomically. A failure rolls back the entire list. Inherited AI review policy
captures a History draft instead of changing the live tree. Approval checks current
permissions and link-cycle constraints again. Linked-shell hard deletions remain
non-revertible after approval, matching the existing UI removal behavior.
