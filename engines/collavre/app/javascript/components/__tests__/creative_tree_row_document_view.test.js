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
  el.dataset.documentOpenLabel = "Open";
  if (documentView) el.dataset.viewMode = "document";
  document.body.appendChild(el);
  return el;
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
    expect(el.querySelector(".creative-document-open")).toBeNull();
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

  test("edits without a selection API", async () => {
    jest.spyOn(window, "getSelection").mockReturnValue(null);
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, container());
    const handler = editClicks(el);

    el.querySelector(".creative-content").click();

    expect(handler).toHaveBeenCalledTimes(1);
  });

  test("the open link is labelled and enters the creative", async () => {
    window.Turbo = { visit: jest.fn() };
    const el = await mountRow({ creativeId: "8", canWrite: true, linkUrl: "/creatives/8" }, container());
    const link = el.querySelector(".creative-document-open");

    expect(link.getAttribute("href")).toBe("/creatives/8");
    expect(link.getAttribute("aria-label")).toBe("Open");
    expect(link.getAttribute("title")).toBe("Open");

    const event = new window.MouseEvent("click", { bubbles: true, cancelable: true });
    link.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(window.Turbo.visit).toHaveBeenCalledWith("/creatives/8", undefined);
  });

  test("the open link advances the workspace frame when inside it", async () => {
    window.Turbo = { visit: jest.fn() };
    const frame = document.createElement("turbo-frame");
    frame.id = "creative-workspace-content";
    document.body.appendChild(frame);
    const parent = container();
    frame.appendChild(parent);
    const el = await mountRow({ creativeId: "8", linkUrl: "/creatives/8" }, parent);

    el.querySelector(".creative-document-open").click();

    expect(window.Turbo.visit).toHaveBeenCalledWith("/creatives/8", {
      action: "advance",
      frame: "creative-workspace-content",
    });
  });

  test.each([
    ["meta", { metaKey: true }],
    ["ctrl", { ctrlKey: true }],
    ["shift", { shiftKey: true }],
    ["alt", { altKey: true }],
    ["middle button", { button: 1 }],
  ])("a %s click on the open link is left to the browser", async (_name, init) => {
    window.Turbo = { visit: jest.fn() };
    const el = await mountRow({ creativeId: "8", linkUrl: "/creatives/8" }, container());
    const link = el.querySelector(".creative-document-open");
    // jsdom would try to navigate on an un-prevented anchor click.
    link.addEventListener("click", (e) => e.preventDefault());
    const event = new window.MouseEvent("click", { bubbles: true, cancelable: true, ...init });

    link.dispatchEvent(event);

    expect(window.Turbo.visit).not.toHaveBeenCalled();
  });

  test("no open link without a destination, and an empty label when none is provided", async () => {
    const parent = container();
    const none = await mountRow({ creativeId: "8" }, parent);
    expect(none.querySelector(".creative-document-open")).toBeNull();

    const empty = await mountRow({ creativeId: "7", linkUrl: "" }, parent);
    expect(empty.querySelector(".creative-document-open")).toBeNull();

    delete parent.dataset.documentOpenLabel;
    const unlabelled = await mountRow({ creativeId: "9", linkUrl: "/creatives/9" }, parent);
    expect(unlabelled.querySelector(".creative-document-open").getAttribute("aria-label")).toBe("");
  });

  test("the title edits on a plain click, but not on its links or in select mode", async () => {
    stubSelection(true);
    const el = await mountRow({ creativeId: "5", canWrite: true, isTitle: true }, container());
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
});

describe("creative-tree-row in tree view", () => {
  test("a title click does nothing", async () => {
    const el = await mountRow({ creativeId: "5", canWrite: true, isTitle: true }, container({ documentView: false }));
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
});
