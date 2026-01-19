# Unified Filter Pipeline Design

> **Status**: Implementation Complete (2026-01-19)
> **Key Change**: `no_access` is stored in cache to override public shares

## Design Background

### Previous Problems

The original `IndexQuery` had scattered filter logic across multiple branches:

- **Comment filter**: Own logic with `select { |c| readable?(c) }`, no ancestor resolution, no progress calculation
- **Search filter**: Complex UNION queries, partial ancestor resolution
- **Tag filter**: Uses `has_permission?`, `CreativeHierarchy` for ancestors, calculates progress_map
- **ID query**: Uses `children_with_permission`
- **Root query**: Different logic again

### Problem Summary

| Problem | Description |
|---------|-------------|
| No filter combination | Cannot apply tags + search + completion status simultaneously |
| Inconsistent permission checks | Mixed use of `readable?`, `has_permission?`, `select` |
| Inconsistent ancestor resolution | Different ancestor inclusion logic per filter |
| Inconsistent progress calculation | Only tag filter calculates progress_map |
| O(n) permission checks | Individual permission check per result |

---

## Unified Design

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         IndexQuery                               │
│  - Entry point, result formatting                                │
│  - Calls FilterPipeline                                          │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                       FilterPipeline                             │
│  1. apply_filters() → Intersection of all filters                │
│  2. resolve_ancestors() → Include ancestors                      │
│  3. filter_by_permission() → O(1) permission check               │
│  4. calculate_progress() → Build progress map                    │
└────────────────────────────┬────────────────────────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ProgressFilter│    │  TagFilter   │    │ SearchFilter │
│  (complete)  │    │    (tags)    │    │   (search)   │
└──────────────┘    └──────────────┘    └──────────────┘
        │                    │                    │
        ▼                    ▼                    ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│CommentFilter │    │  DateFilter  │    │AssigneeFilter│
│  (comments)  │    │    (date)    │    │  (assignee)  │
└──────────────┘    └──────────────┘    └──────────────┘
```

### Core Principles

1. **All filters pass through FilterPipeline**
2. **Filters are combinable** (intersection)
3. **Permissions checked via creative_shares_caches in O(1)**
4. **Ancestor resolution uses consistent logic**

---

## Implementation Details

### FilterPipeline

**Location**: `app/services/creatives/filter_pipeline.rb`

**Result Structure**:
- `matched_ids`: IDs directly matching filters
- `allowed_ids`: IDs after ancestor inclusion + permission filtering
- `progress_map`: ID → progress mapping
- `overall_progress`: Average progress of matched items

**Available Filters**:
- `ProgressFilter`: Filter by completion status (min/max progress)
- `TagFilter`: Filter by tag labels
- `SearchFilter`: Search in description and comments
- `CommentFilter`: Filter by comment existence
- `DateFilter`: Filter by target_date on labels
- `AssigneeFilter`: Filter by label owner

### Permission Filtering Logic

1. **For logged-in users**:
   - Check user-specific cache entries first
   - If `no_access`, add to denied set
   - Otherwise, add to accessible set
   - Check public shares (exclude those denied by user-specific `no_access`)
   - Include owned creatives as fallback

2. **For anonymous users**:
   - Only check public shares (user_id = nil)
   - Exclude `no_access` entries

**Key Point**: User-specific `no_access` overrides public share access.

---

## Filter Combination Example

**Before (Original)**:
- Tags + search cannot be applied simultaneously
- One filter would be ignored

**After (Unified)**:
- All filters can be combined
- Example: `tags=[1,2] AND search="foo" AND incomplete AND has_comments`
- Result: Items with tag 1 or 2 AND containing "foo" AND progress < 1.0 AND having comments

---

## Migration Plan

### Phase 1: Cache Table and Basic Structure ✅
- [x] Create FilterPipeline
- [x] Implement basic filters (Progress, Tag, Search)
- [x] Create creative_shares_caches table
- [x] PermissionCacheBuilder service
- [x] PermissionChecker O(1) lookup

### Phase 2: Additional Filters ✅
- [x] CommentFilter
- [x] DateFilter
- [x] AssigneeFilter

### Phase 3: Permission System Integration ✅
- [x] `no_access` overrides public share
- [x] User-specific entry priority in `children_with_permission`
- [x] Propagate `no_access` in rebuild paths

### Phase 4: IndexQuery Refactoring (Planned)
- [ ] Unify resolve_creatives
- [ ] Remove individual filter branches
- [ ] Full FilterPipeline adoption

### Phase 5: Controller/View Updates (Planned)
- [ ] CSR optimization (HTML/JSON separation)
- [ ] Add `any_filter_active?` helper
- [ ] Call `expires_now` for filter results

### Phase 6: TreeBuilder/JS Improvements (Planned)
- [ ] Delegate `skip_creative?` logic to FilterPipeline
- [ ] Strengthen expansion_controller.js ID extraction

---

## Implementation Notes (Edge Cases)

### 1. Public Share Permission Check (Security)

**Problem**: When user is nil, returning all IDs bypasses permission checks.

**Solution**: Anonymous users should only access public shares. Always check `creative_shares_caches` with `user_id: nil` condition.

**Required Tests**:
- Anonymous user can access public-shared creative
- Anonymous user cannot access private creative
- Logged-in user can access both public and private shares

### 2. Missing Permission Check in HTML Path (Security)

**Problem**: Setting `@parent_creative` without permission check exposes metadata (og:title, etc.)

**Solution**: Always check `has_permission?` before assigning `@parent_creative` in HTML responses.

### 3. Browser Caching Causes Stale Filter Results

**Problem**: 304 Not Modified responses show stale data when filters are applied.

**Solution**: Call `expires_now` when any filter is active.

### 4. Sequence Sorting Inconsistency

**Problem**: Linked Creative (Shell Creative with origin_id) has its own sequence.

**Solution**: Sort by shell's sequence, not origin's sequence. TreeBuilder should consistently use `creative.sequence`.

### 5. N+1 Query Prevention

**Problem**: Additional query per node in TreeBuilder.

**Solution**: Preload necessary data (shares cache) before building nodes.

### 6. FK Constraint Order on Deletion

**Problem**: Creative deletion fails due to FK constraints on cache/permission records.

**Solution**: Use `dependent: :delete_all` on `creative_shares_caches` association, or delete cache records before creative.

### 7. Direct Child vs Linked Origin Distinction

**Problem**: Confusion when same Creative is referenced by both parent_id and origin_id.

**Solution**: Check `creative.origin_id.present?` to identify Shell Creatives. Display link icon in TreeBuilder for Shell Creatives.

### 8. Expansion State Storage (Fallback Needed)

**Problem**: Creative ID extraction fails with various URL patterns (`/creatives/:id`, `/creatives?id=...`).

**Solution**: Try multiple extraction methods:
1. URL path pattern
2. URL query parameter
3. Title row attribute (fallback)

### 9. Ancestor Share Inheritance on Cache Rebuild

**Problem**: When Creative moves (parent_id changes), it must inherit ancestor shares from new location.

**Solution**: On parent_id change, delete existing cache for subtree and rebuild from new ancestors. Include `no_access` shares for public share override.

### 10. Progress Calculation for Shell Creatives

**Problem**: Shell Creative has nil progress, delegated from origin.

**Solution**: When calculating progress_map, check `origin_id.present?` and use `origin.progress` for Shell Creatives.

---

## Improvements from Feature Branch

### 1. Controller CSR Optimization (HTML/JSON Separation)

Skip full tree query on HTML requests; load data via JSON for CSR.

**Benefits**:
- Faster initial HTML page load
- Reduced unnecessary DB queries
- Cache prevention with `expires_now` for filter results

### 2. TreeBuilder Simplification

Delegate `skip_creative?` logic to FilterPipeline.

**Benefits**:
- Remove code duplication (filter logic in one place)
- Improved maintainability
- No TreeBuilder changes needed when adding new filters

### 3. Controller `any_filter_active?` Helper

**Purpose**:
- Call `expires_now` for filter results (prevent caching)
- Check filter active state in JSON response

### 4. View Improvement: Pass Only Filter Parameters

Pass only necessary filter parameters in JSON requests instead of all query parameters.

**Benefits**:
- Prevent unnecessary parameter propagation
- Keep URLs clean

### 5. expansion_controller.js Improvement

Strengthen current creative ID extraction with multiple fallback methods.

---

## Expected Benefits

| Improvement | Before | After |
|-------------|--------|-------|
| Permission check | O(depth) × n | O(1) |
| Filter combination | Not possible | Possible |
| Code duplication | 4 branches | 1 pipeline |
| Adding new filter | Add branch | Add class |
| Test maintainability | Scattered | Centralized |
| HTML initial load | Full query | Minimal query (CSR) |
| TreeBuilder complexity | Duplicated filter logic | Delegated & simplified |
