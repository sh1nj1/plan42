# Linked Creative system design and behavior

## Concept and structure
- The `Creative` model includes an `origin_id` self-referencing column. When `origin_id` is present, the record is treated as a "Linked Creative."
- A Linked Creative delegates most fields to the origin Creative, keeping only the owner (user) and parent as its own values.

## Creation and sharing workflow
- When a Creative is shared through `CreativeShare`, the system automatically creates a Linked Creative owned by the recipient.
- If a Linked Creative with the same `origin_id` and `user_id` already exists, it is not duplicated.
- Linked Creative records store only `origin_id`, `user_id`, and `parent_id`, while validations run solely on the origin Creative (`unless: -> { origin_id.present? }`).

## Model behavior and permissions
- Linked Creatives override getters and helper methods to read data from the origin Creative.
    - Examples: `progress`, `description`, `user`, `children`, and similar accessors.
    - Implemented via helper methods such as `effective_attribute`, `effective_description`, and `effective_origin`.
- Authorization relies on `has_permission?`, granting access to the owner and anyone with a shared link.
- Tree and parent lookups go through `owning_parent`, which returns the parent Creative owned by the current user, falling back to the origin's parent when necessary.
- `children_with_permission` returns only the origin's children that the current user is allowed to see.

## Progress and tree updates
- When a Linked Creative's progress changes,
    - The parent of the origin Creative and every Linked Creative referencing that origin are updated in turn.
- `update_parent_progress` synchronizes linked creatives and refreshes the parent's progress.

## Controller and view behavior
- **creatives_controller.rb**
    - The `index` action queries children by `parent_id`, then filters them in Ruby (`children_with_permission`) to include only entries the user can access.
    - Both owners and shared users can access the `parent_creative`.
- **creative_shares_controller.rb**
    - Creates Linked Creatives based on the origin record whenever a share occurs.
- **creatives_helper.rb**
    - Provides helper methods to pull details such as the description from the Linked Creative's origin when rendering the tree.
- **index.html.erb**
    - Uses `owning_parent` when navigating to the parent node.
    - Renders the tree with only the children that pass the permission filter.

## Additional notes
- Linked Creative updates and deletions cascade to ensure related parent and child progress values remain consistent.
- All behaviors described here are implemented and verified in the codebase.

---

This document reflects the current implementation as of 2025-05-28.
