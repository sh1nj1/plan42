/**
 * Text selection on the creative list.
 *
 * The `.creative-tree` wrapper carries `draggable="true"` so rows can be
 * reordered, but a draggable ancestor makes the browser turn mousedown+move
 * into an HTML5 drag gesture — native drag-to-select over the row text was
 * impossible. The component now drops the attribute while the pointer is down
 * over `.creative-content` (restoring it on mouseup/dragend), and skips the
 * click-to-navigate behavior when the click ends with a non-collapsed text
 * selection (navigating would destroy the selection the user just made).
 */

import { jest } from "@jest/globals";

// The component calls `customElements.define(...)` at module-eval time and reads
// `customElements` as a bare global. The jest environment only exposes it on
// `window`, so bridge it before importing the component.
beforeAll(() => {
  if (typeof globalThis.customElements === "undefined") {
    globalThis.customElements = window.customElements;
  }
});

async function mountRow(props) {
  await import("../creative_tree_row.js");
  const el = document.createElement("creative-tree-row");
  Object.assign(el, props);
  document.body.appendChild(el);
  await el.updateComplete;
  return el;
}

function treeOf(el) {
  return el.querySelector(".creative-tree");
}

function contentOf(el) {
  return el.querySelector(".creative-content");
}

function mouseDown(target, opts = {}) {
  target.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0, ...opts }));
}

function mouseUpWindow() {
  window.dispatchEvent(new window.MouseEvent("mouseup"));
}

function mouseMoveWindow(opts = {}) {
  window.dispatchEvent(new window.MouseEvent("mousemove", opts));
}

function click(target) {
  target.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
}

afterEach(() => {
  document.body.innerHTML = "";
  jest.restoreAllMocks();
  delete window.Turbo;
});

describe("creative-tree-row text selection", () => {
  describe("draggable toggling on mousedown over content", () => {
    test("left mousedown on content disables row drag until mouseup", async () => {
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true });
      const tree = treeOf(el);
      expect(tree.getAttribute("draggable")).toBe("true");

      mouseDown(contentOf(el));
      // With draggable off, the browser starts a text selection instead of a
      // row drag, and drag_drop's handleDragStart guard ignores the row.
      expect(tree.getAttribute("draggable")).toBe("false");

      mouseUpWindow();
      expect(tree.getAttribute("draggable")).toBe("true");
    });

    test("dragend also restores draggable (native selection drag path)", async () => {
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true });
      const tree = treeOf(el);

      mouseDown(contentOf(el));
      expect(tree.getAttribute("draggable")).toBe("false");

      window.dispatchEvent(new window.Event("dragend"));
      expect(tree.getAttribute("draggable")).toBe("true");

      // The restore listeners are one-shot: a later unrelated mouseup must not
      // touch the attribute again after it has been restored.
      tree.setAttribute("draggable", "false");
      mouseUpWindow();
      expect(tree.getAttribute("draggable")).toBe("false");
    });

    test("non-left button keeps the row draggable", async () => {
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true });

      mouseDown(contentOf(el), { button: 2 });
      expect(treeOf(el).getAttribute("draggable")).toBe("true");
    });

    test("select mode leaves mousedown to the select-mode controller", async () => {
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true, selectMode: true });
      const tree = treeOf(el);
      expect(tree.getAttribute("draggable")).toBe("true");

      mouseDown(contentOf(el));
      expect(tree.getAttribute("draggable")).toBe("true");
    });

    test("an active select-mode container leaves mousedown to the controller", async () => {
      // select_mode_controller.toggle() cannot reflect onto rows that are
      // already rendered, so it publishes the mode on its container element.
      // Flipping draggable here would make handleRowMouseDown take its
      // !isDraggable branch and deselect a row instead of dragging the bundle.
      const container = document.createElement("div");
      container.className = "select-mode-active";
      document.body.appendChild(container);

      await import("../creative_tree_row.js");
      const el = document.createElement("creative-tree-row");
      Object.assign(el, { creativeId: "1", parentId: "", level: 2, canWrite: true });
      container.appendChild(el);
      await el.updateComplete;

      mouseDown(contentOf(el));
      expect(treeOf(el).getAttribute("draggable")).toBe("true");

      // Leaving select mode restores normal text-selection behavior.
      container.classList.remove("select-mode-active");
      mouseDown(contentOf(el));
      expect(treeOf(el).getAttribute("draggable")).toBe("false");
      mouseUpWindow();
    });

    test("losing window focus restores draggable", async () => {
      // Pressing on the text and releasing in another window (Alt+Tab) delivers
      // neither mouseup nor dragend, which would strand the row non-draggable.
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true });
      const tree = treeOf(el);

      mouseDown(contentOf(el));
      expect(tree.getAttribute("draggable")).toBe("false");

      window.dispatchEvent(new window.Event("blur"));
      expect(tree.getAttribute("draggable")).toBe("true");

      // One-shot: the row is drag-armed again on the next press.
      mouseDown(contentOf(el));
      expect(tree.getAttribute("draggable")).toBe("false");
      mouseUpWindow();
      expect(tree.getAttribute("draggable")).toBe("true");
    });

    test("focus moving inside the page does not cut the selection short", async () => {
      // blur does not bubble, but a capturing window listener would still see
      // an inner element losing focus and restore draggable mid-gesture.
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true });
      const tree = treeOf(el);

      mouseDown(contentOf(el));
      contentOf(el).dispatchEvent(new window.Event("blur"));
      expect(tree.getAttribute("draggable")).toBe("false");

      mouseUpWindow();
      expect(tree.getAttribute("draggable")).toBe("true");
    });

    test("mousedown leaves a row that is not drag-enabled alone", async () => {
      // A row rendered without the draggable attribute never took part in
      // drag-and-drop; the handler must not add the attribute on its way out.
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true });
      const tree = treeOf(el);
      tree.removeAttribute("draggable");

      mouseDown(contentOf(el));
      expect(tree.hasAttribute("draggable")).toBe(false);

      mouseUpWindow();
      expect(tree.hasAttribute("draggable")).toBe(false);
    });

    test("a pointer move with no button held re-arms the row", async () => {
      // Releasing outside the viewport without changing focus delivers neither
      // mouseup, dragend nor blur; the pointer coming back with the button up
      // is the only signal that the gesture ended.
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true });
      const tree = treeOf(el);

      mouseDown(contentOf(el));
      mouseMoveWindow({ buttons: 1 }); // still dragging — leave the row alone
      expect(tree.getAttribute("draggable")).toBe("false");

      mouseMoveWindow({ buttons: 0 });
      expect(tree.getAttribute("draggable")).toBe("true");

      // One-shot: a later move must not touch the attribute again.
      tree.setAttribute("draggable", "false");
      mouseMoveWindow({ buttons: 0 });
      expect(tree.getAttribute("draggable")).toBe("false");
    });

    test("a stale disarmed row re-arms itself on the next press", async () => {
      // Belt and braces for the same lost-release case: even with no pointer
      // move in between, the next press must not bail out on the guard and
      // strand the row non-draggable.
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true });
      const tree = treeOf(el);

      mouseDown(contentOf(el));
      expect(tree.getAttribute("draggable")).toBe("false");

      // Simulate the release never arriving: press again on the content.
      mouseDown(contentOf(el));
      expect(tree.getAttribute("draggable")).toBe("false");

      // The stale gesture's listeners were dropped, so this press owns the
      // restore and a single mouseup fully re-arms the row.
      mouseUpWindow();
      expect(tree.getAttribute("draggable")).toBe("true");
    });

    test("removing a row mid-gesture drops its window listeners", async () => {
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true });
      const tree = treeOf(el);

      mouseDown(contentOf(el));
      expect(tree.getAttribute("draggable")).toBe("false");

      el.remove();
      expect(tree.getAttribute("draggable")).toBe("true");

      // Nothing is listening any more: window events must not touch the row.
      tree.setAttribute("draggable", "false");
      mouseUpWindow();
      mouseMoveWindow({ buttons: 0 });
      window.dispatchEvent(new window.Event("blur"));
      expect(tree.getAttribute("draggable")).toBe("false");
    });
  });

  describe("click-to-navigate vs text selection", () => {
    test("click with a non-collapsed selection does not navigate", async () => {
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true, linkUrl: "/creatives/1" });
      window.Turbo = { visit: jest.fn() };
      jest.spyOn(window, "getSelection").mockReturnValue({ isCollapsed: false });

      click(contentOf(el));

      expect(window.Turbo.visit).not.toHaveBeenCalled();
    });

    test("plain click (collapsed selection) still navigates", async () => {
      const el = await mountRow({ creativeId: "1", parentId: "", level: 2, canWrite: true, linkUrl: "/creatives/1" });
      window.Turbo = { visit: jest.fn() };
      jest.spyOn(window, "getSelection").mockReturnValue({ isCollapsed: true });

      click(contentOf(el));

      // Outside a turbo-frame workspace the row passes no visit options.
      expect(window.Turbo.visit).toHaveBeenCalledWith("/creatives/1", undefined);
    });
  });
});
