import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode,
  $isParagraphNode,
  KEY_TAB_COMMAND
} from "lexical"
import { HeadingNode, QuoteNode, registerRichText } from "@lexical/rich-text"
import {
  ListNode,
  ListItemNode,
  $createListNode,
  $createListItemNode,
  $isListNode,
  registerList
} from "@lexical/list"
import { registerListTabIndentation } from "../list_tab_indent"

function buildListEditor() {
  const editor = createEditor({
    namespace: "test",
    onError(error) {
      throw error
    },
    nodes: [HeadingNode, QuoteNode, ListNode, ListItemNode]
  })
  // registerRichText handles INDENT/OUTDENT_CONTENT_COMMAND; registerList turns
  // the resulting indent change into real nested list structure.
  registerRichText(editor)
  registerList(editor)
  registerListTabIndentation(editor)
  return editor
}

function countNestedLists(root) {
  let nested = 0
  const walk = (node) => {
    if (typeof node.getChildren !== "function") return
    node.getChildren().forEach((child) => {
      if ($isListNode(child)) nested += 1
      walk(child)
    })
  }
  walk(root)
  return nested
}

describe("registerListTabIndentation", () => {
  it("nests the current list item on Tab", () => {
    const editor = buildListEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const ul = $createListNode("bullet")
        const a = $createListItemNode()
        a.append($createTextNode("a"))
        const b = $createListItemNode()
        const textB = $createTextNode("b")
        b.append(textB)
        ul.append(a, b)
        root.append(ul)
        // Select the text node (a real cursor), not the list item element, so
        // the indent command resolves the block to the ListItemNode.
        textB.selectEnd()
      },
      { discrete: true }
    )

    // Before: one top-level list, no nested lists.
    editor.read(() => {
      expect(countNestedLists($getRoot())).toBe(1)
    })

    const handled = editor.dispatchCommand(KEY_TAB_COMMAND, {
      preventDefault: () => {},
      shiftKey: false
    })
    expect(handled).toBe(true)

    // After: a nested list now exists (the second item became a child list).
    editor.read(() => {
      expect(countNestedLists($getRoot())).toBeGreaterThan(1)
    })
  })

  it("un-nests a nested item on Shift+Tab", () => {
    const editor = buildListEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const ul = $createListNode("bullet")
        const a = $createListItemNode()
        a.append($createTextNode("a"))
        const b = $createListItemNode()
        const textB = $createTextNode("b")
        b.append(textB)
        ul.append(a, b)
        root.append(ul)
        textB.selectEnd()
      },
      { discrete: true }
    )
    // Nest first.
    editor.dispatchCommand(KEY_TAB_COMMAND, { preventDefault: () => {}, shiftKey: false })
    editor.read(() => {
      expect(countNestedLists($getRoot())).toBeGreaterThan(1)
    })

    // Place selection back on the (now nested) "b" and outdent.
    editor.update(
      () => {
        const root = $getRoot()
        const target = root
          .getAllTextNodes()
          .find((n) => n.getTextContent() === "b")
        target.selectEnd()
      },
      { discrete: true }
    )
    const handled = editor.dispatchCommand(KEY_TAB_COMMAND, {
      preventDefault: () => {},
      shiftKey: true
    })
    expect(handled).toBe(true)
    editor.read(() => {
      expect(countNestedLists($getRoot())).toBe(1)
    })
  })

  it("Shift+Tab on a top-level item removes it from the list (becomes a paragraph)", () => {
    const editor = buildListEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const ul = $createListNode("bullet")
        const a = $createListItemNode()
        const textA = $createTextNode("a")
        a.append(textA)
        ul.append(a)
        root.append(ul)
        textA.selectEnd()
      },
      { discrete: true }
    )

    const handled = editor.dispatchCommand(KEY_TAB_COMMAND, {
      preventDefault: () => {},
      shiftKey: true
    })
    expect(handled).toBe(true)

    editor.read(() => {
      const root = $getRoot()
      // The whole list is gone; the item is now a top-level paragraph.
      expect(root.getChildren().some($isListNode)).toBe(false)
      const only = root.getFirstChild()
      expect($isParagraphNode(only)).toBe(true)
      expect(only.getTextContent()).toBe("a")
    })
  })

  it("Shift+Tab on a middle top-level item splits the surrounding list", () => {
    const editor = buildListEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const ul = $createListNode("bullet")
        const a = $createListItemNode()
        a.append($createTextNode("a"))
        const b = $createListItemNode()
        const textB = $createTextNode("b")
        b.append(textB)
        const c = $createListItemNode()
        c.append($createTextNode("c"))
        ul.append(a, b, c)
        root.append(ul)
        textB.selectEnd()
      },
      { discrete: true }
    )

    const handled = editor.dispatchCommand(KEY_TAB_COMMAND, {
      preventDefault: () => {},
      shiftKey: true
    })
    expect(handled).toBe(true)

    editor.read(() => {
      const root = $getRoot()
      const kinds = root.getChildren().map((child) =>
        $isListNode(child) ? `list[${child.getTextContent()}]` : `p[${child.getTextContent()}]`
      )
      // a stays in the first list, b becomes a paragraph, c moves to a trailing list.
      expect(kinds).toEqual(["list[a]", "p[b]", "list[c]"])
    })
  })

  it("ignores Tab outside a list (returns false, no preventDefault)", () => {
    const editor = buildListEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const p = $createParagraphNode()
        p.append($createTextNode("plain"))
        root.append(p)
        p.selectEnd()
      },
      { discrete: true }
    )

    let prevented = false
    const handled = editor.dispatchCommand(KEY_TAB_COMMAND, {
      preventDefault: () => {
        prevented = true
      },
      shiftKey: false
    })
    expect(handled).toBe(false)
    expect(prevented).toBe(false)
  })
})
