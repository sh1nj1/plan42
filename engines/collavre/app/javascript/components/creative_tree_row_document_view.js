// Document view renders the same <creative-tree-row> elements as the tree, but
// the body is for reading, selecting and editing. The mode lives on an ancestor
// (see creatives/document_view_controller.js) so lazily added rows pick it up.
// The title row sits beside the tree, so it only has the controller's class.
import { html, nothing } from "lit";

const DOCUMENT_TREE_SELECTOR = '[data-view-mode="document"]';
const DOCUMENT_VIEW_SELECTOR = `${DOCUMENT_TREE_SELECTOR}, .creative-document-view`;
const SELECT_MODE_SELECTOR = "[data-select-mode-active]";
const INTERACTIVE_SELECTOR = "a, button, input, img, video, audio";
const DRAG_HANDLE_SELECTOR = '.creative-drag-handle[draggable="true"]';
const OPEN_EDITOR_SELECTOR = ":scope > .creative-tree > #inline-edit-form";
const OVERLAY_SELECTOR = '.popup-menu, .popup-box, dialog, [role="dialog"], [class*="modal"]';
const EDITOR_UI_SELECTOR = `#inline-edit-form, ${OVERLAY_SELECTOR}`;
const LEAVING_LINK_SELECTOR = 'a[href]:not([href^="#"]):not([target="_blank"]):not([download])';

// Clicks that already closed the editor, so the row under them opens nothing.
const editorClosingClicks = new WeakSet();

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
// A row the user cannot write keeps the slot empty, so rows stay aligned.
export function renderDragHandle(row) {
  if (!isDocumentView(row)) return nothing;
  if (!row.canWrite) return html`<span class="creative-action-btn creative-drag-handle" style="visibility: hidden" aria-hidden="true"></span>`;
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

// Select mode keeps a selected row selected on mousedown so it can be dragged.
// A document view body is no drag source, so only its handle counts there.
export function isRowDragSource(tree, target) {
  if (isDocumentView(tree)) return Boolean(target.closest?.(DRAG_HANDLE_SELECTOR));
  return tree.getAttribute("draggable") !== "false";
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

// The shared form stays in the page hidden once closed; only a visible one is
// an editor the user is still in.
function closeOpenEditor() {
  const editor = document.getElementById("inline-edit-form");
  if (!editor || editor.style.display === "none") return false;
  document.getElementById("inline-close")?.click();
  return true;
}

function hasTextSelection() {
  const selection = window.getSelection?.();
  return Boolean(selection) && !selection.isCollapsed;
}

// A plain click on a link that loads another page in this tab.
function leavesPage(event) {
  if (event.metaKey || event.ctrlKey || event.shiftKey) return false;
  return Boolean(event.target.closest?.(LEAVING_LINK_SELECTOR));
}

// While an editor is open in document view, a plain click outside it closes
// it, as its close button does: on a row, the title or the empty page around
// them. Controls, the editor's own popups and other panels keep it open. A
// link that leaves the page closes it too: the draft would otherwise go with
// the page, ahead of its debounced save. Runs in the capture phase (see
// creatives/document_view_controller.js), ahead of the row's own click handling.
export function handleDocumentOutsideClick(root, event) {
  const target = event.target;
  if (!root.contains(target) && !target.contains(root)) return;
  if (root.matches(SELECT_MODE_SELECTOR) || target.closest?.(EDITOR_UI_SELECTOR)) return;
  if (leavesPage(event)) return void closeOpenEditor();
  if (target.closest?.(INTERACTIVE_SELECTOR) || hasTextSelection()) return;
  if (closeOpenEditor()) editorClosingClicks.add(event);
}

// A click that ends a selection drag must keep the selection and stay out of
// the editor; only a plain click on an editable row opens it. While an editor
// is open, a click on another row closes it, as its close button does, and
// opens nothing.
export function handleDocumentBodyClick(row, event) {
  if (selectModeActive(row)) return;
  if (event.target.closest(INTERACTIVE_SELECTOR)) return;
  if (hasTextSelection()) return;
  if (editorClosingClicks.has(event) || closeOpenEditor()) return;
  if (!row.canWrite) return;
  row.dispatchEditClick(row.querySelector(".edit-inline-btn"));
}

export function handleDocumentTitleClick(row, event) {
  if (!isDocumentView(row)) return;
  handleDocumentBodyClick(row, event);
}
