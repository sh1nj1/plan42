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
  $isListItemNode,
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

  it("Shift+Tab on a top-level item with a nested child list never puts a list inside a paragraph", () => {
    const editor = buildListEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const ul = $createListNode("bullet")
        const a = $createListItemNode()
        a.append($createTextNode("a"))
        const child = $createListItemNode()
        const childText = $createTextNode("a1")
        child.append(childText)
        ul.append(a, child)
        root.append(ul)
        childText.selectEnd()
      },
      { discrete: true }
    )

    // Tab on "a1" nests it under "a" via the real @lexical/list machinery, so the
    // tree matches what a user actually builds (not a hand-rolled approximation).
    editor.dispatchCommand(KEY_TAB_COMMAND, { preventDefault: () => {}, shiftKey: false })

    editor.update(
      () => {
        const root = $getRoot()
        const topList = root.getFirstChild()
        topList.getFirstChild().getFirstChild().selectEnd() // caret into "a"
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
      // "a" leaves the list as a paragraph and that paragraph must hold no list block.
      const paragraph = root.getChildren().find($isParagraphNode)
      expect(paragraph).toBeDefined()
      expect(paragraph.getTextContent()).toBe("a")
      expect(paragraph.getChildren().some($isListNode)).toBe(false)
      // "a1" was a child of the removed "a", so it must be PROMOTED to a top-level
      // item of the trailing list — not left as an orphan <li><ul> wrapper.
      const trailingList = root.getChildren().filter($isListNode).pop()
      const directItems = trailingList
        .getChildren()
        .filter((li) => $isListItemNode(li) && !$isListNode(li.getFirstChild()))
        .map((li) => li.getTextContent())
      expect(directItems).toContain("a1")
      // No orphan nested-list wrapper survives at the trailing list's top level.
      const hasOrphanWrapper = trailingList
        .getChildren()
        .some((li) => $isListItemNode(li) && $isListNode(li.getFirstChild()))
      expect(hasOrphanWrapper).toBe(false)
      // The original list must not linger as an empty/orphan list before the
      // paragraph: only the single trailing list should remain at the root, and no
      // empty list anywhere (it would serialize as stray blank lines in Markdown).
      const rootLists = root.getChildren().filter($isListNode)
      expect(rootLists.length).toBe(1)
      expect(rootLists[0]).toBe(trailingList)
    })
  })

  it("Shift+Tab promotes only the removed item's children, leaving later items' nesting intact", () => {
    const editor = buildListEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const ul = $createListNode("bullet")
        const a = $createListItemNode()
        a.append($createTextNode("a"))
        const b = $createListItemNode()
        b.append($createTextNode("b"))
        const b1 = $createListItemNode()
        const textB1 = $createTextNode("b1")
        b1.append(textB1)
        ul.append(a, b, b1)
        root.append(ul)
        textB1.selectEnd()
      },
      { discrete: true }
    )

    // Nest "b1" under "b" via the real machinery.
    editor.dispatchCommand(KEY_TAB_COMMAND, { preventDefault: () => {}, shiftKey: false })

    // Caret into top-level "a" and outdent it.
    editor.update(
      () => {
        const root = $getRoot()
        root.getFirstChild().getFirstChild().getFirstChild().selectEnd()
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
      // "a" has no children, so nothing is promoted; "b1" stays nested under "b".
      const trailingList = root.getChildren().filter($isListNode).pop()
      const topTexts = trailingList
        .getChildren()
        .filter((li) => $isListItemNode(li) && !$isListNode(li.getFirstChild()))
        .map((li) => li.getTextContent())
      expect(topTexts).toContain("b")
      expect(topTexts).not.toContain("b1")
      // b1 remains nested (one wrapper holding b1's sublist).
      expect(countNestedLists(root)).toBeGreaterThan(0)
      expect(root.getTextContent()).toContain("b1")
    })
  })

  it("Shift+Tab on a list nested in a blockquote removes the list formatting", () => {
    const editor = buildListEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        // A list whose parent is a QuoteNode, not the root — `> - item`.
        const quote = new QuoteNode()
        const ul = $createListNode("bullet")
        const a = $createListItemNode()
        const textA = $createTextNode("quoted")
        a.append(textA)
        ul.append(a)
        quote.append(ul)
        root.append(quote)
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
      // The list must be gone (no `<ul>` anywhere), the text survives, and no
      // list block remains — `> item` instead of an unchanged `> - item`.
      expect(countNestedLists(root)).toBe(0)
      expect(root.getTextContent()).toContain("quoted")
    })
  })

  it("Shift+Tab splitting an ordered list keeps the trailing numbering", () => {
    const editor = buildListEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const ol = $createListNode("number")
        const a = $createListItemNode()
        a.append($createTextNode("a"))
        const b = $createListItemNode()
        const textB = $createTextNode("b")
        b.append(textB)
        const c = $createListItemNode()
        c.append($createTextNode("c"))
        ol.append(a, b, c)
        root.append(ol)
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
      const lists = root.getChildren().filter($isListNode)
      // a stays in the first ordered list; c moves to a trailing ordered list that
      // continues numbering from 3 (b was 2), not restarting at 1.
      const trailing = lists[lists.length - 1]
      expect(trailing.getListType()).toBe("number")
      expect(trailing.getStart()).toBe(3)
      expect(trailing.getTextContent()).toBe("c")
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
