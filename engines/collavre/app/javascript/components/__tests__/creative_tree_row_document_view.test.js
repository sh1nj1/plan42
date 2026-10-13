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
  test("a click on another row closes the open editor instead of moving it", async () => {
    const parent = container();
    const edited = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, parent);
    const other = await mountRow({ creativeId: "9", canWrite: true, linkUrl: "/creatives/9" }, parent);
    const reader = await mountRow({ creativeId: "10", canWrite: false, linkUrl: "/creatives/10" }, parent);
    const editor = document.createElement("div");
    editor.id = "inline-edit-form";
    const close = document.createElement("button");
    close.id = "inline-close";
    editor.appendChild(close);
    edited.querySelector(".creative-tree").appendChild(editor);
    const closed = jest.fn();
    close.addEventListener("click", closed);
    const handler = editClicks(other);
    stubSelection(true);

    other.querySelector(".creative-content").click();
    reader.querySelector(".creative-content").click();
    expect(closed).toHaveBeenCalledTimes(2);
    expect(handler).not.toHaveBeenCalled();

    // Once closed, the hidden form is no open editor and the click edits again.
    editor.style.display = "none";
    other.querySelector(".creative-content").click();
    expect(closed).toHaveBeenCalledTimes(2);
    expect(handler).toHaveBeenCalledTimes(1);

    // A form that lost its close button still blocks the switch.
    editor.style.display = "";
    close.remove();
    other.querySelector(".creative-content").click();
    expect(handler).toHaveBeenCalledTimes(1);
  });

  test("a plain click outside the open editor closes it", async () => {
    const { handleDocumentOutsideClick } = await import("../creative_tree_row_document_view.js");
    const root = document.createElement("div");
    root.className = "creative-document-view";
    root.innerHTML = `
      <div class="blank"></div>
      <button class="control"></button>
      <div class="share-modal"><p class="in-modal"></p></div>
      <div id="inline-edit-form"><button id="inline-close"></button><p class="draft"></p></div>`;
    const page = document.createElement("main");
    const panel = document.createElement("aside");
    page.append(root, panel);
    document.body.appendChild(page);
    const editor = root.querySelector("#inline-edit-form");
    const closed = jest.fn();
    root.querySelector("#inline-close").addEventListener("click", closed);
    const clickOn = (target) => {
      const event = { target };
      handleDocumentOutsideClick(root, event);
      return event;
    };
    stubSelection(true);

    // Inside the editor, on controls, in overlays and in other panels: stays open.
    clickOn(root.querySelector(".draft"));
    clickOn(root.querySelector(".control"));
    clickOn(root.querySelector(".in-modal"));
    clickOn(panel);
    expect(closed).not.toHaveBeenCalled();

    // A click that ends a selection drag keeps the editor too.
    stubSelection(false);
    clickOn(root.querySelector(".blank"));
    expect(closed).not.toHaveBeenCalled();
    stubSelection(true);

    // Select mode owns clicks while it is on.
    root.setAttribute("data-select-mode-active", "");
    clickOn(root.querySelector(".blank"));
    expect(closed).not.toHaveBeenCalled();
    root.removeAttribute("data-select-mode-active");

    // Empty space in the view and the page around it close the editor.
    clickOn(root.querySelector(".blank"));
    clickOn(page);
    clickOn(document);
    expect(closed).toHaveBeenCalledTimes(3);

    // Nothing to close once the form is hidden.
    editor.style.display = "none";
    clickOn(root.querySelector(".blank"));
    expect(closed).toHaveBeenCalledTimes(3);
  });

  test("a link that leaves the page waits for the open editor's save before it is followed", async () => {
    const { handleDocumentOutsideClick } = await import("../creative_tree_row_document_view.js");
    const root = document.createElement("div");
    root.className = "creative-document-view";
    root.innerHTML = `
      <a class="leaves" href="/creatives/9"><b class="inner">go</b></a>
      <a class="new-tab" href="https://example.com" target="_blank">out</a>
      <a class="download" href="/files/1" download>file</a>
      <a class="anchor" href="#section">jump</a>
      <a class="bare">no href</a>
      <div id="inline-edit-form"><button id="inline-close" disabled></button><a class="in-editor" href="/x">x</a></div>`;
    document.body.appendChild(root);
    const editor = root.querySelector("#inline-edit-form");
    let settle;
    const flush = jest.fn(() => new Promise((resolve) => { settle = resolve; }));
    window.creativeRowEditor = { flush };
    const followed = jest.fn((event) => event.preventDefault());
    root.querySelector(".leaves").addEventListener("click", followed);
    const capture = (event) => handleDocumentOutsideClick(root, event);
    document.addEventListener("click", capture, true);
    const clickOn = (selector, keys = {}) => {
      const event = new window.MouseEvent("click", { bubbles: true, cancelable: true, ...keys });
      root.querySelector(selector).dispatchEvent(event);
      return event;
    };
    stubSelection(true);

    // These stay on the page, so the editor and its draft stay too.
    clickOn(".new-tab");
    clickOn(".download");
    clickOn(".anchor");
    clickOn(".bare");
    clickOn(".in-editor");
    clickOn(".leaves", { metaKey: true });
    clickOn(".leaves", { ctrlKey: true });
    clickOn(".leaves", { shiftKey: true });
    expect(flush).not.toHaveBeenCalled();
    followed.mockClear();

    // The click is held back until the save lands, even while the close
    // button is disabled by a pending upload.
    const held = clickOn(".inner");
    expect(held.defaultPrevented).toBe(true);
    expect(flush).toHaveBeenCalledTimes(1);
    expect(followed).not.toHaveBeenCalled();
    editor.style.display = "none";
    settle(true);
    await Promise.resolve();
    await Promise.resolve();
    expect(followed).toHaveBeenCalledTimes(1);

    // A failed save keeps the draft in the editor and the user on the page.
    editor.style.display = "";
    clickOn(".leaves");
    settle(false);
    await Promise.resolve();
    await Promise.resolve();
    expect(flush).toHaveBeenCalledTimes(2);
    expect(followed).toHaveBeenCalledTimes(1);

    // With no editor open the link is left alone.
    editor.style.display = "none";
    expect(clickOn(".leaves").defaultPrevented).toBe(true);
    expect(flush).toHaveBeenCalledTimes(2);
    expect(followed).toHaveBeenCalledTimes(2);

    document.removeEventListener("click", capture, true);
    delete window.creativeRowEditor;
  });

  test("a link that unloads the page waits for the save wherever it sits", async () => {
    const { handleDocumentOutsideClick } = await import("../creative_tree_row_document_view.js");
    const root = document.createElement("div");
    root.className = "creative-document-view";
    root.innerHTML = `
      <div class="popup-box"><a class="popup-external" href="https://example.com/a">a</a><a class="popup-app" href="/creatives/9">b</a></div>
      <div id="inline-edit-form"><a class="in-editor" href="https://example.com/e">e</a></div>`;
    const outside = document.createElement("div");
    outside.innerHTML = `
      <a class="external" href="https://example.com/b">b</a>
      <a class="file" href="/robots.txt">robots</a>
      <a class="page" href="/help.html">help</a>
      <span data-turbo="false"><a class="no-turbo" href="/session">out</a></span>
      <a class="app" href="/creatives/10">in app</a>`;
    document.body.append(root, outside);
    const editor = root.querySelector("#inline-edit-form");
    // As the real flush does, this closes the editor it saves.
    const flush = jest.fn(() => {
      editor.style.display = "none";
      return Promise.resolve(true);
    });
    window.creativeRowEditor = { flush };
    const followed = jest.fn((event) => event.preventDefault());
    document.body.addEventListener("click", followed);
    const capture = (event) => handleDocumentOutsideClick(root, event);
    document.addEventListener("click", capture, true);
    const clickOn = async (selector) => {
      editor.style.display = "";
      document.querySelector(selector).dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
      await Promise.resolve();
      await Promise.resolve();
    };
    stubSelection(true);

    // Turbo keeps the document for these, so the scheduled save still lands.
    await clickOn(".app");
    await clickOn(".page");
    await clickOn(".popup-app");
    // A link in the editor itself is the editor's to handle.
    await clickOn(".in-editor");
    expect(flush).not.toHaveBeenCalled();
    expect(followed).toHaveBeenCalledTimes(4);

    // Each of these unloads the page: saved first, then followed once.
    for (const [index, selector] of [".external", ".file", ".no-turbo", ".popup-external"].entries()) {
      await clickOn(selector);
      expect(flush).toHaveBeenCalledTimes(index + 1);
      expect(followed).toHaveBeenCalledTimes(index + 5);
    }

    document.removeEventListener("click", capture, true);
    delete window.creativeRowEditor;
  });

  test("link clicks repeated while the save is on its way are dropped until it settles", async () => {
    const { handleDocumentOutsideClick } = await import("../creative_tree_row_document_view.js");
    const root = document.createElement("div");
    root.className = "creative-document-view";
    root.innerHTML = `
      <a class="leaves" href="/creatives/9">go</a>
      <a class="other" href="/creatives/10">elsewhere</a>
      <div id="inline-edit-form"></div>`;
    document.body.appendChild(root);
    const editor = root.querySelector("#inline-edit-form");
    let settle;
    const flush = jest.fn(() => new Promise((resolve) => { settle = resolve; }));
    window.creativeRowEditor = { flush };
    const followed = jest.fn((event) => event.preventDefault());
    root.addEventListener("click", followed);
    const capture = (event) => handleDocumentOutsideClick(root, event);
    document.addEventListener("click", capture, true);
    const clickOn = (selector) => {
      const event = new window.MouseEvent("click", { bubbles: true, cancelable: true });
      root.querySelector(selector).dispatchEvent(event);
      return event;
    };
    stubSelection(true);

    clickOn(".leaves");
    // An upload keeps the editor on screen; a plain save hides it at once.
    // Either way the page must not be left before the first flush settles.
    expect(clickOn(".leaves").defaultPrevented).toBe(true);
    editor.style.display = "none";
    expect(clickOn(".leaves").defaultPrevented).toBe(true);
    expect(clickOn(".other").defaultPrevented).toBe(true);
    await Promise.resolve();
    expect(flush).toHaveBeenCalledTimes(1);
    expect(followed).not.toHaveBeenCalled();

    // Only the link that was held is followed, once.
    settle(true);
    await Promise.resolve();
    await Promise.resolve();
    expect(followed).toHaveBeenCalledTimes(1);
    expect(followed.mock.calls[0][0].target).toBe(root.querySelector(".leaves"));

    // A flush that throws releases the hold as well.
    editor.style.display = "";
    flush.mockImplementationOnce(() => Promise.reject(new Error("offline")));
    clickOn(".leaves");
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    expect(followed).toHaveBeenCalledTimes(1);
    editor.style.display = "none";
    clickOn(".other");
    expect(followed).toHaveBeenCalledTimes(2);

    document.removeEventListener("click", capture, true);
    delete window.creativeRowEditor;
  });

  test("a click that closed the editor does not open the row under it", async () => {
    const { handleDocumentOutsideClick } = await import("../creative_tree_row_document_view.js");
    const root = container();
    root.classList.add("creative-document-view");
    const edited = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, root);
    const other = await mountRow({ creativeId: "9", canWrite: true, linkUrl: "/creatives/9" }, root);
    const editor = document.createElement("div");
    editor.id = "inline-edit-form";
    const close = document.createElement("button");
    close.id = "inline-close";
    editor.appendChild(close);
    edited.querySelector(".creative-tree").appendChild(editor);
    // The real close button hides the form at once.
    close.addEventListener("click", () => { editor.style.display = "none"; });
    const handler = editClicks(other);
    stubSelection(true);
    const capture = (event) => handleDocumentOutsideClick(root, event);
    document.addEventListener("click", capture, true);

    other.querySelector(".creative-content").click();
    expect(editor.style.display).toBe("none");
    expect(handler).not.toHaveBeenCalled();

    other.querySelector(".creative-content").click();
    expect(handler).toHaveBeenCalledTimes(1);
    document.removeEventListener("click", capture, true);
  });

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

  test("the handle is a localized navigation link without opening the editor", async () => {
    const parent = container();
    parent.dataset.dragHandleHint = "Click to open this creative; drag and drop to move it.";
    const row = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, parent);
    const handle = row.querySelector(".creative-drag-handle");
    const edits = editClicks(row);
    const event = new window.MouseEvent("click", { bubbles: true, cancelable: true });
    // Cancel only after checking the component, to avoid jsdom navigation.
    parent.addEventListener("click", (click) => {
      expect(click.defaultPrevented).toBe(false);
      click.preventDefault();
    }, { once: true });

    handle.querySelector("svg").dispatchEvent(event);

    expect(handle.tagName).toBe("A");
    expect(handle.getAttribute("href")).toBe("/creatives/8");
    expect(handle.title).toBe(parent.dataset.dragHandleHint);
    expect(handle.getAttribute("aria-label")).toBe(`8: ${parent.dataset.dragHandleHint}`);
    expect(handle.hasAttribute("aria-hidden")).toBe(false);
    expect(handle.dataset.turboAction).toBe("advance");
    expect(handle.dataset.turboPrefetch).toBe("false");
    expect(edits).not.toHaveBeenCalled();
  });

  test.each([
    ["Click to open this creative; drag and drop to move it.", "<h2>First &amp; second</h2>", "First & second"],
    ["클릭하면 안으로 이동, 드래그&드롭으로 이동 가능", "<p>첫 문서</p>", "첫 문서"],
    ["Open", "<p>  First\n\t &nbsp; second  </p>", "First second"],
    ["Open", `<p>${"word ".repeat(400)}</p>`, `${"word ".repeat(16).slice(0, 79)}…`],
    ["Open", `<p>${"가".repeat(80)}</p>`, "가".repeat(80)],
    ["Open", `<p>${"😀".repeat(81)}</p>`, `${"😀".repeat(79)}…`],
    ["Open", "<p> &nbsp; \n </p>", "8"]
  ])("the accessible name identifies the target with localized guidance", async (hint, descriptionHtml, name) => {
    const parent = container();
    parent.dataset.dragHandleHint = hint;
    const row = await mountRow({ creativeId: "8", canWrite: true, descriptionHtml }, parent);
    expect(row.querySelector(".creative-drag-handle").getAttribute("aria-label")).toBe(`${name}: ${hint}`);
  });

  test("extracting the handle name parses media in an inert template document", async () => {
    const { renderDragHandle } = await import("../creative_tree_row_document_view.js");
    const row = document.createElement("div");
    container().appendChild(row);
    Object.assign(row, {
      canWrite: true, creativeId: "8", linkUrl: "/creatives/8",
      descriptionHtml: '<p>Media &amp; text</p><img src="/attachment.png"><video src="/clip.mp4"></video><iframe src="/embed"></iframe>'
    });
    const setter = Object.getOwnPropertyDescriptor(Element.prototype, "innerHTML").set;
    const parsed = [];
    jest.spyOn(Element.prototype, "innerHTML", "set").mockImplementation(function (value) {
      setter.call(this, value);
      if (value === row.descriptionHtml) parsed.push(this);
    });

    const result = renderDragHandle(row);

    expect(parsed).toHaveLength(1);
    expect(parsed[0].tagName).toBe("TEMPLATE");
    expect(parsed[0].content.ownerDocument).not.toBe(document);
    expect(parsed[0].content.ownerDocument.defaultView).toBeNull();
    expect(parsed[0].content.querySelectorAll("img, video, iframe")).toHaveLength(3);
    expect(result.values).toContain("Media & text");
  });

  test.each(["row", "ancestor"])("the handle does not navigate in %s select mode", async (mode) => {
    const parent = container();
    if (mode === "ancestor") parent.setAttribute("data-select-mode-active", "");
    const row = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8", selectMode: mode === "row" }, parent);
    const bubbled = jest.fn();
    parent.addEventListener("click", bubbled);
    const event = new window.MouseEvent("click", { bubbles: true, cancelable: true });

    row.querySelector(".creative-drag-handle svg").dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(bubbled).not.toHaveBeenCalled();
  });

  test("a row the user cannot write keeps the handle's slot empty and drags nothing", async () => {
    const { startsRowDrag, isRowDragSource } = await import("../creative_tree_row_document_view.js");
    const el = await mountRow({ creativeId: "8", canWrite: false, linkUrl: "/creatives/8" }, container());
    const tree = el.querySelector(".creative-tree");
    const slot = el.querySelector(".creative-row-start > .creative-drag-handle");

    expect(slot.hasAttribute("draggable")).toBe(false);
    expect(slot.style.visibility).toBe("hidden");
    expect(slot.children).toHaveLength(0);
    expect(startsRowDrag(tree, { target: slot, dataTransfer: {} })).toBe(false);
    expect(isRowDragSource(tree, slot)).toBe(false);
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


describe("document progress background", () => {
  test.each([[0, 100], [0.9, 10], [1, 0], [-1, 100], [2, 0], [undefined, 0], [NaN, 0], [Infinity, 0]])("sizes the unfinished tail for %s", async (progress, width) => {
    const { documentProgressStyle } = await import("../creative_tree_row_document_view.js");
    const style = documentProgressStyle(progress);
    expect(parseFloat(style.split(":")[1])).toBeCloseTo(width);
  });

  test.each([false, true])("reacts to dataset updates for title=%s", async (isTitle) => {
    const row = await mountRow({ creativeId: "8", isTitle }, page().tree);
    row.dataset.progressValue = "0.9";
    await row.updateComplete;
    expect(parseFloat(row.querySelector(".creative-row").style.getPropertyValue("--document-progress-width"))).toBeCloseTo(10);
    row.dataset.progressValue = "1";
    await row.updateComplete;
    expect(row.querySelector(".creative-row").style.getPropertyValue("--document-progress-width")).toBe("0%");
  });
});

 test.each([false, true])("filtered progress drives the background for title=%s", async (isTitle) => {
   const row = await mountRow({ creativeId: "8", isTitle, progressValue: 1, displayProgress: 0 }, page().tree);
   expect(row.querySelector(".creative-row").style.getPropertyValue("--document-progress-width")).toBe("100%");
   expect(row.progressValue).toBe(1);
   row.dataset.displayProgress = "0.9";
   await row.updateComplete;
   expect(parseFloat(row.querySelector(".creative-row").style.getPropertyValue("--document-progress-width"))).toBeCloseTo(10);
   row.removeAttribute("data-display-progress");
   await row.updateComplete;
   expect(row.querySelector(".creative-row").style.getPropertyValue("--document-progress-width")).toBe("0%");
 });
