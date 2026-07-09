import {
  createEditor,
  $getRoot,
  $createParagraphNode,
  $createTextNode,
  $createRangeSelection,
  $setSelection
} from "lexical"
import { HeadingNode, QuoteNode, registerRichText } from "@lexical/rich-text"
import { CodeNode, CodeHighlightNode, $isCodeNode } from "@lexical/code"
import { registerCodeFenceShortcut } from "../code_fence_shortcut"

function buildEditor() {
  const editor = createEditor({
    namespace: "test",
    onError(error) {
      throw error
    },
    nodes: [HeadingNode, QuoteNode, CodeNode, CodeHighlightNode]
  })
  registerRichText(editor)
  registerCodeFenceShortcut(editor)
  return editor
}

// Simulate a user typing `text` into an empty paragraph with the caret at its end,
// so the fence transform sees an active collapsed selection inside the paragraph.
function typeFence(editor, text) {
  editor.update(
    () => {
      const root = $getRoot()
      root.clear()
      const paragraph = $createParagraphNode()
      const textNode = $createTextNode(text)
      paragraph.append(textNode)
      root.append(paragraph)
      const selection = $createRangeSelection()
      selection.anchor.set(textNode.getKey(), text.length, "text")
      selection.focus.set(textNode.getKey(), text.length, "text")
      $setSelection(selection)
    },
    { discrete: true }
  )
}

describe("registerCodeFenceShortcut", () => {
  it("converts a bare ``` fence into an empty code block", () => {
    const editor = buildEditor()
    typeFence(editor, "```")

    editor.read(() => {
      const children = $getRoot().getChildren()
      expect(children).toHaveLength(1)
      expect($isCodeNode(children[0])).toBe(true)
      expect(children[0].getTextContent()).toBe("")
      expect(children[0].getLanguage()).toBeFalsy()
    })
  })

  it("carries the language token from ```ruby", () => {
    const editor = buildEditor()
    typeFence(editor, "```ruby")

    editor.read(() => {
      const codeNode = $getRoot().getFirstChild()
      expect($isCodeNode(codeNode)).toBe(true)
      expect(codeNode.getLanguage()).toBe("ruby")
    })
  })

  it("leaves prose that merely contains backticks untouched", () => {
    const editor = buildEditor()
    typeFence(editor, "run ```code``` inline")

    editor.read(() => {
      const child = $getRoot().getFirstChild()
      expect($isCodeNode(child)).toBe(false)
      expect(child.getTextContent()).toBe("run ```code``` inline")
    })
  })

  it("does not convert a ``` paragraph when the caret is elsewhere (bulk edits)", () => {
    const editor = buildEditor()
    editor.update(
      () => {
        const root = $getRoot()
        root.clear()
        const fence = $createParagraphNode()
        fence.append($createTextNode("```"))
        root.append(fence)
        const other = $createParagraphNode()
        const otherText = $createTextNode("elsewhere")
        other.append(otherText)
        root.append(other)
        // Caret sits in the OTHER paragraph, not the fence line.
        const selection = $createRangeSelection()
        selection.anchor.set(otherText.getKey(), 1, "text")
        selection.focus.set(otherText.getKey(), 1, "text")
        $setSelection(selection)
      },
      { discrete: true }
    )

    editor.read(() => {
      const children = $getRoot().getChildren()
      expect(children.some($isCodeNode)).toBe(false)
    })
  })
})
