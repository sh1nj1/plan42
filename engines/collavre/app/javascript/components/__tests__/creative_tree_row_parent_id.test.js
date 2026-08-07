/**
 * Regression: parentId single source of truth.
 *
 * The tree row component used to render `data-parent-id=${this.parentId ?? nothing}`,
 * which OMITTED the attribute whenever parentId was null. `addNew` derives a new
 * sibling's parent from `prev.dataset.parentId`, so an absent attribute produced an
 * `undefined` parent downstream and lost the real parent for newly-added siblings.
 *
 * The single convention: `data-parent-id` is ALWAYS emitted on `.creative-tree`.
 * A non-empty value is the parent id; "" means "root / no parent". This mirrors the
 * dynamic-creation path (`dataset.parentId = parentId || ''`).
 */

// The component calls `customElements.define(...)` at module-eval time and reads
// `customElements` as a bare global. The jest environment only exposes it on
// `window`, so bridge it before importing the component.
import { jest } from '@jest/globals'

beforeAll(() => {
  if (typeof globalThis.customElements === "undefined") {
    globalThis.customElements = window.customElements;
  }
});

async function mountRow(props, parent = document.body) {
  await import("../creative_tree_row.js");
  const el = document.createElement("creative-tree-row");
  Object.assign(el, props);
  parent.appendChild(el);
  await el.updateComplete;
  return el;
}

// The `.creative-tree` element is what the editor reads via `tree.dataset.parentId`.
function treeOf(el) {
  return el.querySelector(".creative-tree");
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("creative-tree-row parentId convention", () => {
  test("non-title row under a page-title parent keeps the parent id", async () => {
    const el = await mountRow({ creativeId: "8", parentId: "5", level: 2 });
    const tree = treeOf(el);

    // The attribute is always present and carries the real parent id — this is
    // exactly what addNew reads (`prev.dataset.parentId`) when deriving a sibling.
    expect(tree.hasAttribute("data-parent-id")).toBe(true);
    expect(tree.dataset.parentId).toBe("5");
  });

  test("root row emits an explicit empty marker instead of omitting the attribute", async () => {
    const el = await mountRow({ creativeId: "5", parentId: null, level: 1 });
    const tree = treeOf(el);

    // Before the fix this attribute was omitted (ambiguous root vs unknown).
    expect(tree.hasAttribute("data-parent-id")).toBe(true);
    expect(tree.dataset.parentId).toBe("");
  });

  test("title row preserves its own parent (nested page) instead of dropping it", async () => {
    const el = await mountRow({ creativeId: "5", parentId: "2", isTitle: true });
    const tree = treeOf(el);

    expect(tree.classList.contains("creative-tree-title")).toBe(true);
    expect(tree.hasAttribute("data-parent-id")).toBe(true);
    expect(tree.dataset.parentId).toBe("2");
  });

  test("root title row emits explicit empty marker", async () => {
    const el = await mountRow({ creativeId: "5", parentId: null, isTitle: true });
    const tree = treeOf(el);

    expect(tree.hasAttribute("data-parent-id")).toBe(true);
    expect(tree.dataset.parentId).toBe("");
  });

  test("addNew sibling derivation reads the correct parent from a page-title child", async () => {
    // Simulate the editor's else-branch derivation: parentId = prev.dataset.parentId
    // for a child row that lives under a page-title parent (id 5).
    const child = await mountRow({ creativeId: "8", parentId: "5", level: 2 });
    const prev = treeOf(child);

    const derivedParentId = prev.dataset.parentId || "";
    expect(derivedParentId).toBe("5"); // sibling inherits the page-title parent
  });

  test("content navigation stays inside the persistent workspace frame", async () => {
    const frame = document.createElement("turbo-frame");
    frame.id = "creative-workspace-content";
    document.body.appendChild(frame);
    const visit = jest.fn();
    window.Turbo = { visit };
    const el = await mountRow({ creativeId: "8", linkUrl: "/creatives/8" }, frame);

    el.querySelector(".creative-content").dispatchEvent(new window.MouseEvent("click", { bubbles: true }));

    expect(visit).toHaveBeenCalledWith("/creatives/8", {
      action: "advance",
      frame: "creative-workspace-content",
    });
    delete window.Turbo;
  });
});
