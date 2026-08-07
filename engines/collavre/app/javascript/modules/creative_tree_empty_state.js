// Empty-state placeholder ("No sub-creatives found." / "No creatives found.")
// lifecycle for the creative tree.
//
// The placeholder is server-rendered inside #creatives (see creatives/index.html.erb)
// and marked with data-creatives-empty-state. Rows, however, are inserted into that
// same container purely client-side — by the inline row editor (local add) and by the
// websocket broadcast handler (another user / MCP add). Neither path re-renders the
// container, so without an explicit hook the placeholder stays visible next to the
// freshly created row.
//
// hideTreeEmptyState() drops the placeholder as soon as a row lands; restoreTreeEmptyState()
// puts it back when the last row leaves (abandoned new row, delete, broadcast destroy)
// using the original markup cached on the container by the tree controller value.
const EMPTY_STATE_SELECTOR = '[data-creatives-empty-state]';
// Stimulus value attribute on #creatives (creatives--tree controller, emptyHtml value).
// Read via getAttribute because the `creatives--tree` identifier does not survive the
// dataset camelCase mapping in a usable form.
const EMPTY_HTML_ATTRIBUTE = 'data-creatives--tree-empty-html-value';

export function creativeTreeContainer() {
  return document.getElementById('creatives');
}

export function hideTreeEmptyState(container = creativeTreeContainer()) {
  if (!container || !container.querySelectorAll) return;
  container.querySelectorAll(EMPTY_STATE_SELECTOR).forEach((element) => element.remove());
}

export function restoreTreeEmptyState(container = creativeTreeContainer()) {
  if (!container || !container.querySelector) return;
  // Still populated (or the placeholder is already back) — nothing to restore.
  if (container.querySelector('creative-tree-row')) return;
  if (container.querySelector(EMPTY_STATE_SELECTOR)) return;

  const html = container.getAttribute(EMPTY_HTML_ATTRIBUTE);
  if (!html) return;
  container.insertAdjacentHTML('beforeend', html);
}
