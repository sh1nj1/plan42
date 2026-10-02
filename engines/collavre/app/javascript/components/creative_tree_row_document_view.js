// Document view renders the same <creative-tree-row> elements as the tree, but
// the body is for reading, selecting and editing. The mode lives on an ancestor
// (see creatives/document_view_controller.js) so lazily added rows pick it up.
const DOCUMENT_VIEW_SELECTOR = '[data-view-mode="document"]';
const INTERACTIVE_SELECTOR = "a, button, input, img";

export function isDocumentView(row) {
  return row.closest(DOCUMENT_VIEW_SELECTOR) !== null;
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

// A click that ends a selection drag must keep the selection and stay out of
// the editor; only a plain click on an editable row opens it.
export function handleDocumentBodyClick(row) {
  const selection = window.getSelection?.();
  if (selection && !selection.isCollapsed) return;
  if (!row.canWrite) return;
  row.dispatchEditClick(row.querySelector(".edit-inline-btn"));
}

export function handleDocumentTitleClick(row, event) {
  if (!isDocumentView(row) || row.selectMode) return;
  if (event.target.closest(INTERACTIVE_SELECTOR)) return;
  handleDocumentBodyClick(row);
}
