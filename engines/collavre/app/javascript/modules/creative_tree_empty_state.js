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
// hideTreeEmptyState() hides the placeholder as soon as a row lands;
// restoreTreeEmptyState() shows it again when the last row leaves.
//
// The placeholder is toggled rather than removed and re-created: keeping the original
// node means no markup has to be cached and re-parsed as HTML (which would both
// re-introduce an HTML sink and lose the server-rendered button_to CSRF token in the
// "request permission" variant of the placeholder).
//
// The container itself is wiped on every client-side tree load (tree_controller's
// showLoadingIndicator / renderCreativeTree), so on a populated tree the placeholder
// is gone by the time the rows arrive. #creatives-empty-state-template holds a
// pristine copy outside the container; restoreTreeEmptyState() clones it when the
// tree empties out and nothing is left to un-hide. Cloning a <template> is not an
// HTML sink — the browser parsed the markup at page load, server-side-escaped.
const EMPTY_STATE_SELECTOR = '[data-creatives-empty-state]';
const EMPTY_STATE_TEMPLATE_ID = 'creatives-empty-state-template';

export function creativeTreeContainer() {
  return document.getElementById('creatives');
}

function emptyStateElements(container) {
  if (!container || !container.querySelectorAll) return [];
  return Array.from(container.querySelectorAll(EMPTY_STATE_SELECTOR));
}

export function hideTreeEmptyState(container = creativeTreeContainer()) {
  emptyStateElements(container).forEach((element) => {
    element.hidden = true;
    // Belt and braces: `hidden` is a UA-stylesheet rule that any `display` rule
    // on the element would win over.
    element.style.display = 'none';
  });
}

function clonedEmptyStatePlaceholder() {
  const template = document.getElementById(EMPTY_STATE_TEMPLATE_ID);
  if (!template || !template.content) return null;
  return template.content.cloneNode(true).querySelector(EMPTY_STATE_SELECTOR);
}

export function restoreTreeEmptyState(container = creativeTreeContainer()) {
  if (!container || !container.querySelector) return;
  // Still populated — the placeholder stays hidden.
  if (container.querySelector('creative-tree-row')) return;

  const existing = emptyStateElements(container);
  if (existing.length > 0) {
    existing.forEach((element) => {
      element.hidden = false;
      element.style.removeProperty('display');
    });
    return;
  }

  // Nothing to un-hide — the tree render wiped the container. Re-attach a copy.
  const placeholder = clonedEmptyStatePlaceholder();
  if (placeholder) container.appendChild(placeholder);
}
