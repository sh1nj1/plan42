/**
 * Document view: the same row component, but the body is for reading,
 * selecting and editing instead of dragging and navigating.
 */
import { jest } from '@jest/globals'

beforeAll(() => {
  if (typeof globalThis.customElements === "undefined") {
    globalThis.customElements = window.customElements;
  }
  // The component builds its events from the bare global; jsdom only accepts
  // its own Event classes in dispatchEvent.
  globalThis.CustomEvent = window.CustomEvent;
});

function container({ documentView = true } = {}) {
  const el = document.createElement("div");
  el.id = "creatives";
  if (documentView) el.dataset.viewMode = "document";
  document.body.appendChild(el);
  return el;
}

// The page renders the title row beside the tree, under the element that
// carries the document view controller and its class.
function page({ documentView = true } = {}) {
  const root = document.createElement("div");
  root.classList.toggle("creative-document-view", documentView);
  document.body.appendChild(root);
  const tree = container({ documentView });
  root.appendChild(tree);
  return { root, tree };
}

async function mountRow(props, parent) {
  await import("../creative_tree_row.js");
  const el = document.createElement("creative-tree-row");
  Object.assign(el, props);
  parent.appendChild(el);
  await el.updateComplete;
  return el;
}

function editClicks(el) {
  const handler = jest.fn();
  el.addEventListener("creative-edit-click", handler);
  return handler;
}

function stubSelection(isCollapsed) {
  jest.spyOn(window, "getSelection").mockReturnValue({ isCollapsed });
}

afterEach(() => {
  jest.restoreAllMocks();
  delete window.Turbo;
  document.body.innerHTML = "";
});

describe("creative-tree-row in document view", () => {
  test("rows are not drag sources, and become draggable again in tree view", async () => {
    const parent = container();
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, parent);

    expect(el.querySelector(".creative-tree").hasAttribute("draggable")).toBe(false);

    delete parent.dataset.viewMode;
    el.requestUpdate();
    await el.updateComplete;

    expect(el.querySelector(".creative-tree").getAttribute("draggable")).toBe("true");
  });

  test("closing the editor leaves the row a drag source only in tree view", async () => {
    const { restoreRowDraggable } = await import("../creative_tree_row_document_view.js");
    const parent = container();
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, parent);
    const tree = el.querySelector(".creative-tree");

    tree.draggable = false; // what the editor does while it is open
    restoreRowDraggable(tree);
    expect(tree.hasAttribute("draggable")).toBe(false);

    delete parent.dataset.viewMode;
    tree.draggable = false;
    restoreRowDraggable(tree);
    expect(tree.getAttribute("draggable")).toBe("true");
  });

  test("a read-only row in select mode is no drag source in tree view", async () => {
    const parent = container({ documentView: false });
    const el = await mountRow({ creativeId: "8", canWrite: false, selectMode: true, linkUrl: "/creatives/8" }, parent);

    expect(el.querySelector(".creative-tree").hasAttribute("draggable")).toBe(false);
  });

  test("a row being edited stays non-draggable when the view switches", async () => {
    const parent = container();
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, parent);
    const tree = el.querySelector(".creative-tree");
    const editor = document.createElement("div");
    editor.id = "inline-edit-form";
    tree.appendChild(editor); // what the editor does while it is open
    tree.draggable = false;

    delete parent.dataset.viewMode;
    el.requestUpdate();
    await el.updateComplete;
    expect(tree.getAttribute("draggable")).toBe("false");

    parent.dataset.viewMode = "document";
    el.requestUpdate();
    await el.updateComplete;
    expect(tree.getAttribute("draggable")).toBe("false");

    editor.remove();
    delete parent.dataset.viewMode;
    el.requestUpdate();
    await el.updateComplete;
    expect(tree.getAttribute("draggable")).toBe("true");
  });

  test("the hidden editor shell left behind after closing does not lock the row", async () => {
    const { isDragLocked, restoreRowDraggable } = await import("../creative_tree_row_document_view.js");
    const parent = container({ documentView: false });
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, parent);
    const tree = el.querySelector(".creative-tree");
    const editor = document.createElement("div");
    editor.id = "inline-edit-form";
    editor.style.display = "none"; // closed, but still attached to its last row
    tree.appendChild(editor);
    restoreRowDraggable(tree);

    el.requestUpdate(); // what the refresh after a save does
    await el.updateComplete;
    expect(tree.getAttribute("draggable")).toBe("true");

    parent.dataset.viewMode = "document";
    el.requestUpdate();
    await el.updateComplete;
    expect(tree.hasAttribute("draggable")).toBe(false);
    expect(isDragLocked(tree)).toBe(false);
  });

  test("a drag handle replaces the row as the drag source, only in document view", async () => {
    const parent = container();
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, parent);

    const handle = el.querySelector(".creative-row-start > .creative-drag-handle");
    expect(handle.getAttribute("draggable")).toBe("true");

    delete parent.dataset.viewMode;
    el.requestUpdate();
    await el.updateComplete;

    expect(el.querySelector(".creative-drag-handle")).toBeNull();
  });

  test("only the handle starts a row drag, with the row as the drag image", async () => {
    const { startsRowDrag } = await import("../creative_tree_row_document_view.js");
    const parent = container();
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, parent);
    const tree = el.querySelector(".creative-tree");
    const handle = el.querySelector(".creative-drag-handle");
    const dataTransfer = { setDragImage: jest.fn() };

    expect(startsRowDrag(tree, { target: el.querySelector(".creative-content"), dataTransfer })).toBe(false);
    // Dragging selected text starts on a text node, which has no closest().
    expect(startsRowDrag(tree, { target: document.createTextNode("text"), dataTransfer })).toBe(false);
    expect(dataTransfer.setDragImage).not.toHaveBeenCalled();

    expect(startsRowDrag(tree, { target: handle.querySelector("svg"), dataTransfer })).toBe(true);
    expect(dataTransfer.setDragImage).toHaveBeenCalledWith(tree, 0, 0);
    // The touch bridge and older engines may not offer a drag image.
    expect(startsRowDrag(tree, { target: handle, dataTransfer: {} })).toBe(true);
  });

  test("rows still take drops, while an edited row does not in either view", async () => {
    const { isDragLocked, startsRowDrag } = await import("../creative_tree_row_document_view.js");
    const parent = container();
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, parent);
    const tree = el.querySelector(".creative-tree");

    expect(tree.draggable).toBe(false);
    expect(isDragLocked(tree)).toBe(false);
    // The inline editor locks the row it edits.
    tree.draggable = false;
    expect(isDragLocked(tree)).toBe(true);
    tree.removeAttribute("draggable");
    expect(isDragLocked(tree)).toBe(false);

    tree.draggable = false;
    delete parent.dataset.viewMode;
    expect(isDragLocked(tree)).toBe(true);
    expect(startsRowDrag(tree, { target: tree })).toBe(false);
    tree.draggable = true;
    expect(isDragLocked(tree)).toBe(false);
    expect(startsRowDrag(tree, { target: tree })).toBe(true);
  });

  test("the title takes no drops and opts out of touch dragging", async () => {
    const { isDragLocked } = await import("../creative_tree_row_document_view.js");
    const { root, tree } = page();
    const title = await mountRow({ creativeId: "5", canWrite: true, isTitle: true }, root);
    const row = await mountRow({ creativeId: "8", canWrite: true }, tree);
    const titleTree = title.querySelector(".creative-tree");

    expect(isDragLocked(titleTree)).toBe(true);
    expect(titleTree.hasAttribute("data-dnd-disabled")).toBe(true);
    expect(isDragLocked(row.querySelector(".creative-tree"))).toBe(false);

    root.classList.remove("creative-document-view");
    delete tree.dataset.viewMode;
    title.requestUpdate();
    await title.updateComplete;

    expect(isDragLocked(titleTree)).toBe(true);
    expect(titleTree.hasAttribute("data-dnd-disabled")).toBe(false);
  });

  test("a plain body click opens the editor instead of navigating", async () => {
    window.Turbo = { visit: jest.fn() };
    stubSelection(true);
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, container());
    const handler = editClicks(el);

    el.querySelector(".creative-content").click();

    expect(window.Turbo.visit).not.toHaveBeenCalled();
    expect(handler).toHaveBeenCalledTimes(1);
    expect(handler.mock.calls[0][0].detail).toMatchObject({
      creativeId: "8",
      component: el,
      button: el.querySelector(".edit-inline-btn"),
      treeElement: el.querySelector(".creative-tree"),
    });
  });

  test("a click that ends a selection drag keeps the selection and does not edit", async () => {
    stubSelection(false);
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, container());
    const handler = editClicks(el);

    el.querySelector(".creative-content").click();

    expect(handler).not.toHaveBeenCalled();
  });

  test("read-only rows neither edit nor navigate on a body click", async () => {
    window.Turbo = { visit: jest.fn() };
    stubSelection(true);
    const el = await mountRow({ creativeId: "8", canWrite: false, linkUrl: "/creatives/8" }, container());
    const handler = editClicks(el);

    el.querySelector(".creative-content").click();

    expect(handler).not.toHaveBeenCalled();
    expect(window.Turbo.visit).not.toHaveBeenCalled();
  });

  test("links inside the body keep their default behavior", async () => {
    stubSelection(true);
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, container());
    el.descriptionHtml = '<a href="#anchor">link</a>';
    await el.updateComplete;
    const handler = editClicks(el);

    el.querySelector(".creative-content a").click();

    expect(handler).not.toHaveBeenCalled();
  });

  test("media controls inside the body keep their default behavior", async () => {
    stubSelection(true);
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, container());
    el.descriptionHtml = '<video controls src="/clip.mp4"></video><audio controls src="/clip.mp3"></audio>';
    await el.updateComplete;
    const handler = editClicks(el);

    el.querySelector(".creative-content video").click();
    el.querySelector(".creative-content audio").click();

    expect(handler).not.toHaveBeenCalled();
  });

  test("edits without a selection API", async () => {
    jest.spyOn(window, "getSelection").mockReturnValue(null);
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, container());
    const handler = editClicks(el);

    el.querySelector(".creative-content").click();

    expect(handler).toHaveBeenCalledTimes(1);
  });

  test("the title edits on a plain click, but not on its links or in select mode", async () => {
    stubSelection(true);
    const el = await mountRow({ creativeId: "5", canWrite: true, isTitle: true }, page().root);
    el.descriptionHtml = 'Title <a href="#anchor">link</a>';
    await el.updateComplete;
    const handler = editClicks(el);

    el.querySelector(".creative-title-content a").click();
    expect(handler).not.toHaveBeenCalled();

    el.querySelector(".creative-title-content").click();
    expect(handler).toHaveBeenCalledTimes(1);

    el.selectMode = true;
    await el.updateComplete;
    el.querySelector(".creative-title-content").click();
    expect(handler).toHaveBeenCalledTimes(1);
  });

  test("select mode toggled from the menu keeps body and title clicks out of the editor", async () => {
    stubSelection(true);
    const { root, tree } = page();
    const body = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, tree);
    const title = await mountRow({ creativeId: "5", canWrite: true, isTitle: true }, root);
    const handler = jest.fn();
    root.addEventListener("creative-edit-click", handler);

    root.toggleAttribute("data-select-mode-active", true);
    body.querySelector(".creative-content").click();
    title.querySelector(".creative-title-content").click();
    expect(handler).not.toHaveBeenCalled();

    root.toggleAttribute("data-select-mode-active", false);
    body.querySelector(".creative-content").click();
    title.querySelector(".creative-title-content").click();
    expect(handler).toHaveBeenCalledTimes(2);
  });
});

describe("creative-tree-row in tree view", () => {
  test("a title click does nothing", async () => {
    const el = await mountRow({ creativeId: "5", canWrite: true, isTitle: true }, page({ documentView: false }).root);
    const handler = editClicks(el);

    el.querySelector(".creative-title-content").click();

    expect(handler).not.toHaveBeenCalled();
  });

  test("a body click still navigates, with or without Turbo", async () => {
    window.Turbo = { visit: jest.fn() };
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, container({ documentView: false }));
    const handler = editClicks(el);

    el.querySelector(".creative-content").click();

    expect(handler).not.toHaveBeenCalled();
    expect(window.Turbo.visit).toHaveBeenCalledWith("/creatives/8", undefined);

    el.linkUrl = "#";
    await el.updateComplete;
    el.querySelector(".creative-content").click();
    expect(window.Turbo.visit).toHaveBeenCalledTimes(1);
  });

  test("a body click advances the workspace frame when inside it", async () => {
    window.Turbo = { visit: jest.fn() };
    const frame = document.createElement("turbo-frame");
    frame.id = "creative-workspace-content";
    document.body.appendChild(frame);
    const parent = container({ documentView: false });
    frame.appendChild(parent);
    const el = await mountRow({ creativeId: "8", linkUrl: "/creatives/8" }, parent);

    el.querySelector(".creative-content").click();

    expect(window.Turbo.visit).toHaveBeenCalledWith("/creatives/8", {
      action: "advance",
      frame: "creative-workspace-content",
    });
  });

  test("falls back to a plain location change without Turbo", async () => {
    const el = await mountRow({ creativeId: "8", linkUrl: "#section-8" }, container({ documentView: false }));

    el.querySelector(".creative-content").click();

    expect(window.location.hash).toBe("#section-8");
  });

  test("the edit button still dispatches the edit event with itself as the button", async () => {
    const el = await mountRow({ creativeId: "8", canWrite: true }, container({ documentView: false }));
    const handler = editClicks(el);

    el.querySelector(".edit-inline-btn").click();

    expect(handler.mock.calls[0][0].detail.button).toBe(el.querySelector(".edit-inline-btn"));
  });

  test("the edit button takes its accessible name from the page, in either view", async () => {
    const { root, tree } = page();
    root.dataset.editLabel = "Edit creative";
    const row = await mountRow({ creativeId: "9", canWrite: true }, tree);
    const title = await mountRow({ creativeId: "1", canWrite: true, isTitle: true }, root);
    const unlabeled = await mountRow({ creativeId: "8", canWrite: true }, container({ documentView: false }));

    expect(row.querySelector(".edit-inline-btn").getAttribute("aria-label")).toBe("Edit creative");
    expect(title.querySelector(".edit-inline-btn").getAttribute("aria-label")).toBe("Edit creative");
    expect(unlabeled.querySelector(".edit-inline-btn").hasAttribute("aria-label")).toBe(false);
    expect(row.querySelector(".edit-inline-btn").hasAttribute("style")).toBe(false);

    const reader = await mountRow({ creativeId: "7", canWrite: false }, tree);
    const hidden = reader.querySelector(".edit-inline-btn");
    expect(hidden.style.visibility).toBe("hidden");
    expect(hidden.hasAttribute("aria-label")).toBe(false);
  });
});
