import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode,
  $createRangeSelection,
  $setSelection,
  DecoratorNode
} from "lexical"

// Minimal top-level decorator (stands in for ImageNode/VideoNode/AttachmentNode)
// so we can assert the toggle never removes media blocks. Its text content is
// empty, exactly like real media nodes.
class TestMediaNode extends DecoratorNode {
  static getType() {
    return "test-media"
  }
  static clone(node) {
    return new TestMediaNode(node.__key)
  }
  createDOM() {
    return document.createElement("div")
  }
  updateDOM() {
    return false
  }
  decorate() {
    return null
  }
}
import { HeadingNode, QuoteNode, registerRichText } from "@lexical/rich-text"
import { CodeNode, CodeHighlightNode, $createCodeNode, $isCodeNode } from "@lexical/code"
import { ListNode, ListItemNode } from "@lexical/list"
import {
  TableNode,
  TableRowNode,
  TableCellNode,
  $createTableNodeWithDimensions,
  $isTableNode
} from "@lexical/table"
import { $toggleCodeBlockForSelection } from "../code_block_toggle"

function buildEditor() {
  const editor = createEditor({
    namespace: "test",
    onError(error) {
      throw error
    },
    nodes: [
      HeadingNode,
      QuoteNode,
      CodeNode,
      CodeHighlightNode,
      ListNode,
      ListItemNode,
      TableNode,
      TableRowNode,
      TableCellNode,
      TestMediaNode
    ]
  })
  registerRichText(editor)
  return editor
}

function appendParagraph(root, text) {
  const paragraph = $createParagraphNode()
  paragraph.append($createTextNode(text))
  root.append(paragraph)
  return paragraph
}

describe("$toggleCodeBlockForSelection", () => {
  it("merges every selected paragraph into a single code block (not just the last line)", () => {
    const editor = buildEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const a = appendParagraph(root, "line one")
        appendParagraph(root, "line two")
        const c = appendParagraph(root, "line three")
        const selection = $createRangeSelection()
        selection.anchor.set(a.getFirstChild().getKey(), 0, "text")
        selection.focus.set(c.getFirstChild().getKey(), "line three".length, "text")
        $setSelection(selection)
        $toggleCodeBlockForSelection()
      },
      { discrete: true }
    )

    editor.read(() => {
      const children = $getRoot().getChildren()
      expect(children).toHaveLength(1)
      expect($isCodeNode(children[0])).toBe(true)
      expect(children[0].getTextContent()).toBe("line one\nline two\nline three")
    })
  })

  it("converts a single collapsed-selection paragraph into a code block", () => {
    const editor = buildEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const p = appendParagraph(root, "hello")
        p.getFirstChild().selectEnd()
        $toggleCodeBlockForSelection()
      },
      { discrete: true }
    )

    editor.read(() => {
      const children = $getRoot().getChildren()
      expect(children).toHaveLength(1)
      expect($isCodeNode(children[0])).toBe(true)
      expect(children[0].getTextContent()).toBe("hello")
    })
  })

  it("toggles a selected code block back into one paragraph per line", () => {
    const editor = buildEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const codeNode = $createCodeNode()
        codeNode.append($createTextNode("a\nb"))
        root.append(codeNode)
        codeNode.selectEnd()
        $toggleCodeBlockForSelection()
      },
      { discrete: true }
    )

    editor.read(() => {
      const children = $getRoot().getChildren()
      expect(children.some($isCodeNode)).toBe(false)
      expect(children.map((child) => child.getTextContent())).toEqual(["a", "b"])
    })
  })

  it("absorbs a mixed selection (heading + paragraph) into one code block", () => {
    const editor = buildEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const heading = new HeadingNode("h1")
        heading.append($createTextNode("Title"))
        root.append(heading)
        const body = appendParagraph(root, "body")
        const selection = $createRangeSelection()
        selection.anchor.set(heading.getFirstChild().getKey(), 0, "text")
        selection.focus.set(body.getFirstChild().getKey(), "body".length, "text")
        $setSelection(selection)
        $toggleCodeBlockForSelection()
      },
      { discrete: true }
    )

    editor.read(() => {
      const children = $getRoot().getChildren()
      expect(children).toHaveLength(1)
      expect($isCodeNode(children[0])).toBe(true)
      expect(children[0].getTextContent()).toBe("Title\nbody")
    })
  })

  it("does not flatten a table when the caret is inside a table cell", () => {
    const editor = buildEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const table = $createTableNodeWithDimensions(2, 2, false)
        root.append(table)
        const cellParagraph = table.getFirstChild().getFirstChild().getFirstChild()
        cellParagraph.append($createTextNode("cell"))
        cellParagraph.getFirstChild().selectEnd()
        $toggleCodeBlockForSelection()
      },
      { discrete: true }
    )

    editor.read(() => {
      const children = $getRoot().getChildren()
      expect(children.some($isTableNode)).toBe(true)
      expect(children.some($isCodeNode)).toBe(false)
    })
  })

  it("merges surrounding text but leaves a selected media (decorator) block intact", () => {
    const editor = buildEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const before = appendParagraph(root, "before")
        const media = new TestMediaNode()
        root.append(media)
        const after = appendParagraph(root, "after")
        const selection = $createRangeSelection()
        selection.anchor.set(before.getFirstChild().getKey(), 0, "text")
        selection.focus.set(after.getFirstChild().getKey(), "after".length, "text")
        $setSelection(selection)
        $toggleCodeBlockForSelection()
      },
      { discrete: true }
    )

    editor.read(() => {
      const children = $getRoot().getChildren()
      // Media block must survive; the two text paragraphs merge into one code block.
      expect(children.some((c) => c.getType() === "test-media")).toBe(true)
      const codeBlocks = children.filter($isCodeNode)
      expect(codeBlocks).toHaveLength(1)
      expect(codeBlocks[0].getTextContent()).toBe("before\nafter")
    })
  })
})
