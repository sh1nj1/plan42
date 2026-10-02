// Document view renders the same <creative-tree-row> elements as the tree, but
// the body is for reading, selecting and editing. The mode lives on an ancestor
// (see creatives/document_view_controller.js) so lazily added rows pick it up.
// The title row sits beside the tree, so it only has the controller's class.
import { html, nothing } from "lit";

const DOCUMENT_TREE_SELECTOR = '[data-view-mode="document"]';
const DOCUMENT_VIEW_SELECTOR = `${DOCUMENT_TREE_SELECTOR}, .creative-document-view`;
const SELECT_MODE_SELECTOR = "[data-select-mode-active]";
const INTERACTIVE_SELECTOR = "a, button, input, img, video, audio";
const DRAG_HANDLE_SELECTOR = ".creative-drag-handle";
const OPEN_EDITOR_SELECTOR = ":scope > .creative-tree > #inline-edit-form";

export function isDocumentView(row) {
  return row.closest(DOCUMENT_VIEW_SELECTOR) !== null;
}

// Document view selects text over the body, so the row is no drag source.
// The inline editor sits inside the row it edits and locks dragging until it
// closes; a re-render, such as a view switch, must not undo that lock. Once
// closed, the hidden form stays in its last row and no longer counts.
export function rowDraggableAttr(row) {
  const editor = row.querySelector(OPEN_EDITOR_SELECTOR);
  if (editor && editor.style.display !== "none") return "false";
  if (isDocumentView(row)) return nothing;
  return !row.selectMode || row.canWrite ? "true" : nothing;
}

// The body selects text, so a hover handle is the only drag source of a
// document view row. It takes the slot of the edit button, which is hidden.
export function renderDragHandle(row) {
  if (!isDocumentView(row)) return nothing;
  return html`
    <span class="creative-action-btn creative-drag-handle" draggable="true" aria-hidden="true">
      <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
        <circle cx="5.5" cy="3.5" r="1.3"/><circle cx="10.5" cy="3.5" r="1.3"/>
        <circle cx="5.5" cy="8" r="1.3"/><circle cx="10.5" cy="8" r="1.3"/>
        <circle cx="5.5" cy="12.5" r="1.3"/><circle cx="10.5" cy="12.5" r="1.3"/>
      </svg>
    </span>
  `;
}

// Document view rows are never draggable themselves, yet they still take drops.
// The title beside the tree never does, nor does a row whose editor holds the
// explicit lock; elsewhere a non-draggable row is one that is being edited.
export function isDragLocked(tree) {
  if (tree.draggable !== false) return false;
  return tree.hasAttribute("draggable") || tree.closest(DOCUMENT_TREE_SELECTOR) === null;
}

// The touch opt-out sits on the tree, which the title is not part of. Without
// it a long press on the title would hold back native text selection.
export function titleDndDisabledAttr(row) {
  return isDocumentView(row) ? "" : nothing;
}

export function startsRowDrag(tree, event) {
  if (!isDocumentView(tree)) return tree.draggable !== false;
  if (!event.target.closest?.(DRAG_HANDLE_SELECTOR)) return false;
  // The browser would otherwise show only the handle as the drag image.
  event.dataTransfer.setDragImage?.(tree, 0, 0);
  return true;
}

// The inline editor turns dragging off while it is open. Closing it hands the
// row back as a drag source only in tree view; render() does not re-run here.
export function restoreRowDraggable(tree) {
  if (isDocumentView(tree)) {
    tree.removeAttribute("draggable");
  } else {
    tree.draggable = true;
  }
}

export function visitRowLink(row) {
  if (!row.linkUrl || row.linkUrl === "#") return;
  if (window.Turbo) {
    const workspaceFrame = row.closest("turbo-frame#creative-workspace-content");
    const options = workspaceFrame
      ? { action: "advance", frame: workspaceFrame.id }
      : undefined;
    window.Turbo.visit(row.linkUrl, options);
  } else {
    window.location.href = row.linkUrl;
  }
}

// Select mode toggled from the overflow menu lives on the select-mode
// controller's element, not on the row's own selectMode property.
function selectModeActive(row) {
  return row.selectMode || row.closest(SELECT_MODE_SELECTOR) !== null;
}

// A click that ends a selection drag must keep the selection and stay out of
// the editor; only a plain click on an editable row opens it.
export function handleDocumentBodyClick(row, event) {
  if (selectModeActive(row)) return;
  if (event.target.closest(INTERACTIVE_SELECTOR)) return;
  const selection = window.getSelection?.();
  if (selection && !selection.isCollapsed) return;
  if (!row.canWrite) return;
  row.dispatchEditClick(row.querySelector(".edit-inline-btn"));
}

export function handleDocumentTitleClick(row, event) {
  if (!isDocumentView(row)) return;
  handleDocumentBodyClick(row, event);
}
