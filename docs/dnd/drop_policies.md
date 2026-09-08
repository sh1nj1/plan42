# Drag and drop outcome policies

The input registry consumes the T1 public legacy MIME readers. Kind detection
uses transfer types only; drop processing reads canonical string IDs. Business
commands and DOM recovery belong to their adapters.

## Creative movement

- Move bundles use the existing atomic reorder API. Only a single local right
  tree move applies optimistic DOM changes, with T2 recovery on failure.
- Link bundles use T2's ordered per-ID requests. Successful links remain after a
  partial failure; completion signals list only successful IDs. Link creation
  never signals that the source moved. Failed IDs must not be retried as if the
  whole bundle failed.
- Workspace placement waits for server success, then refreshes both views while
  preserving view state. A child destination is revealed after success.

## Context additions

- A bundle is deduplicated against direct and inherited contexts and submitted
  as one `update_contexts` PATCH containing the complete direct-context ID list.
  The existing endpoint saves one creative record; no per-item batch API is
  introduced and no subset is considered successful by the client.
- Non-positive, fractional and unsafe numeric IDs are ignored. Duplicate-only
  bundles make no request. Direct-context order and incoming selection order
  are retained.
- Drops are serialized through server save and reload so a second bundle keeps
  additions from the first. A queued drop is cancelled if the popup switches
  creative before it starts.
- HTTP failures, login redirects, HTML responses and network failures do not
  update the local context list or report success. A localized dialog asks the
  user to refresh before retrying: a network failure can leave the server result
  unknown. Successful writes reload the current creative's contexts.
- The existing whole-list endpoint does not provide cross-window concurrency
  control. Concurrent updates from separate windows retain its last-write
  behavior; the local drop queue does not imply a server transaction across tabs.

## Chat links and bundle images

- Canonical IDs produce one link each in selection order, inserted in one text
  update and one input event. Text after the cursor is preserved. Existing links
  in the draft remain valid repeated references; only duplicates within the
  incoming bundle are removed by T1.
- Creative and selected-comment sources share `lib/dnd/bundle_image.js`; image
  content uses text nodes and the temporary element is removed on the next frame.
